#!/usr/bin/perl

# most of codes were copyed from twitter2ircd.pl

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/../extlib", "$FindBin::Bin/../lib");

use Data::Dumper;
use Getopt::Long;
use POE qw(Component::Client::Nowa Component::Server::IRC Component::TSTP);
use YAML;

my $conf = "config.yaml";
GetOptions('-c=s' => \ $conf, '--quiet' => \my $quiet);
$conf or die "Usage: nowa2ircd.pl -c=config.yaml\n";

my $config = YAML::LoadFile($conf) or die $!;

if ($quiet) {
    close STDIN;
    close STDOUT;
    close STDERR;
    exit if fork;
} else {
    # for Ctrl-Z
    POE::Component::TSTP->create();
}

sub msg (@) { print "[msg] ", "@_\n" }
sub err (@) { print "[err] ", "@_\n" }

my $ircd = POE::Component::Server::IRC->spawn(
    alias  => 'ircd',
    config => {
        servername => $config->{irc}->{servername},
        nicklen    => 15,
        network    => 'NowaNET'
    },
);

my $nowa = POE::Component::Client::Nowa->spawn(%{ $config->{nowa} });

POE::Session->create(
    inline_states => {
        _start   => \&_start,
        ircd_daemon_nick => \&ircd_nick,
        ircd_daemon_join => \&ircd_join,
        ircd_daemon_part => \&ircd_part,
        ircd_daemon_quit => \&ircd_quit,
        ircd_daemon_public  => \&ircd_public,

        'nowa.recent' => \&nowa_recent,
        'nowa.recent_success' => \&nowa_recent_success,
        'nowa.channel_recent' => \&nowa_channel_recent,
        'nowa.channel_recent_success' => \&nowa_channel_recent_success,
        'nowa.channels_success' => \&nowa_channels_success,

        bot_join => \&bot_join,
        delay_nowa_recent => \&delay_nowa_recent,
        delay_nowa_channel_recent => \&delay_nowa_channel_recent,
        delay_nowa_channels => \&delay_nowa_channels,

        _default => \&ircd_default,
    },
    options => { trace => 0 },
    heap => { ircd => $ircd, nowa => $nowa, config => $config, previous_recent => [] },
);

$poe_kernel->run();
exit 0;

sub _start {
    my ($kernel,$heap) = @_[KERNEL,HEAP];
    my $conf = $heap->{config}->{irc};

    msg '_start';

    # register ircd to receive events
    $heap->{ircd}->yield('register');
    $heap->{nowa}->yield('register');
    $heap->{ircd}->add_auth(
        mask => $conf->{mask},
        password => $conf->{password}
    );
    $heap->{ircd}->add_listener( port => $conf->{serverport} || 6667 );

    # add super user
    $heap->{ircd}->yield(add_spoofed_nick => { nick => $conf->{botname} });
    $heap->{ircd}->yield(daemon_cmd_join => $conf->{botname}, $conf->{channel});
    $heap->{nowa}->yield('channels');

    $heap->{nicknames} = {};
    $heap->{channel_nicknames} = {};
    $heap->{joined}    = 0;

    undef;
}

sub delay_nowa_recent {
    my($kernel, $heap) = @_[KERNEL, HEAP];

    msg 'delay_nowa_recent';
    if ($heap->{joined}) {
        $heap->{nowa}->yield('recent');
    }
}

sub delay_nowa_channel_recent {
    my($kernel, $heap) = @_[KERNEL, HEAP];

    msg 'delay_nowa_channel_recent';
    $heap->{nowa}->yield('channel_recent');
}

sub delay_nowa_channels {
    my($kernel, $heap) = @_[KERNEL, HEAP];

    msg 'delay_nowa_channels';
    $heap->{nowa}->yield('channels');
}

sub nowa_privmsg {
    my($kernel, $heap, $ret) = @_[KERNEL, HEAP, ARG0];
    my $conf = $heap->{config}->{irc};

    msg 'nowa_privmsg';
    $heap->{ircd}->yield(daemon_cmd_notice => $conf->{botname}, $conf->{channel}, $ret->{text});
}

sub bot_join {
    my($kernel, $heap, $nick, $ch) = @_[KERNEL, HEAP, ARG0, ARG1];

    msg 'bot_join';
    return if $heap->{nicknames}->{$nick};
    $heap->{ircd}->yield(add_spoofed_nick => { nick => $nick });
    $heap->{ircd}->yield(daemon_cmd_join => $nick, $ch);
    $heap->{nicknames}->{$nick} = 1;
}

sub ircd_nick {
    my($kernel, $heap, $nick, $host) = @_[KERNEL, HEAP, ARG0, ARG5];
    my $conf = $heap->{config}->{irc};

    return if $nick eq $conf->{botname};
    return if $heap->{nick_change} || '';
    if (($host || '') eq $conf->{servername}) {
        $heap->{ircd}->_daemon_cmd_join($nick, $conf->{channel});
        $heap->{nick_change} = 1;
        $heap->{ircd}->_daemon_cmd_nick($nick, $conf->{nickname});
        delete $heap->{nick_change};
    }

    $heap->{nick} = $nick;
}

sub nowa_channels_success {
    my($kernel, $heap, $res) = @_[KERNEL, HEAP, ARG0];
    my $conf = $heap->{config}->{irc};

    msg 'nowa_channels_success';
    while (my ($channel, $topic) = each(%$res)) {
        unless ($heap->{bot_joined_channel}->{$channel}) {
            $heap->{bot_joined_channel}->{$channel} = 1;
            $heap->{ircd}->yield(daemon_cmd_join => $conf->{botname}, $channel);
            $heap->{ircd}->yield(daemon_cmd_topic => $conf->{botname}, $channel, $topic);
        }
    }
    $heap->{nowa}->{topics} = $res;
    $kernel->delay('delay_nowa_channels', 1200);
}

sub ircd_join {
    my($kernel, $heap, $user, $ch) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $conf = $heap->{config}->{irc};

    return unless my($nick) = $user =~ /^([^!]+)!/;
    return if $heap->{nicknames}->{$nick};
    return if $nick eq $conf->{botname};
    $heap->{ircd}->yield(add_spoofed_nick => { nick => $nick });
    if ($ch eq $conf->{channel}) {
        $heap->{joined} = 1;
        $heap->{nowa}->yield(update => 'hello, world') if $heap->{config}->{greeting};

        $kernel->delay('delay_nowa_recent', 5);
    } else {
        $kernel->delay('delay_nowa_channel_recent', 15) unless $heap->{initial_channel_recent}++;
    }
}

sub ircd_part {
    my($kernel, $heap, $user, $ch) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $conf = $heap->{config}->{irc};

    return unless my($nick) = $user =~ /^([^!]+)!/;
    return if $heap->{nicknames}->{$nick};
    return if $nick eq $conf->{botname};

    if ($ch eq $conf->{channel}) {
        $heap->{joined} = 0;
        $heap->{nowa}->yield(update => 'good nite!') if $heap->{config}->{greeting};
    }
}

sub ircd_quit {
    my($kernel, $heap, $user) = @_[KERNEL,HEAP,ARG0];
    my $conf = $heap->{config}->{irc};

    return unless my($nick) = $user =~ /^([^!]+)!/;
    return if $heap->{nicknames}->{$nick};
    return if $nick eq $conf->{botname};
    $heap->{joined} = 0;
    $heap->{nowa}->yield(update => 'good nite, yeah!') if $heap->{config}->{greeting};
}

sub ircd_public {
    my($kernel, $heap, $user, $channel, $text) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];
    my $conf = $heap->{config}->{irc};

    my $status = { status => $text };

    if ($channel ne $conf->{channel}) {
        $status->{status} = "$channel $status->{status}";

    } elsif ($text =~ /^[\@\>]([a-z0-9\-]+):?\s+(.+)$/i) {
        my ($nick, $body) = (lc($1), $2);
        my %cache = map { $_->{user} => $_->{id} } reverse( @{ $heap->{previous_recent} } );

        if ($cache{$nick}) {
            $status = {
                parent_id => $cache{$nick},
                status    => $body,
            };
        } else {
            $status->{status} = "$nick: $body",
        }
    }

    $heap->{nowa}->yield(update => $status);
}

sub nowa_recent_success {
    my($kernel, $heap, $ret) = @_[KERNEL, HEAP, ARG0];
    my $conf = $heap->{config}->{irc};

    msg "nowa_recent_success";

    if ($heap->{joined}) {
        my %prev = map { $_->{permalink} => 1 } @{ $heap->{previous_recent} };

        for my $line (reverse @{ $ret }) {
            next if $prev{ $line->{permalink} };

            my $name = $line->{user};
            my $text = $line->{body};

            unless ($heap->{nicknames}->{$name}) {
                $heap->{ircd}->yield(add_spoofed_nick => { nick => $name });
                $heap->{ircd}->yield(daemon_cmd_join => $name, $conf->{channel});
                $heap->{nicknames}->{$name} = 1;
            }

            if ($heap->{config}->{nowa}->{nowa_id} eq $name) {
                $heap->{ircd}->yield(daemon_cmd_topic => $conf->{botname}, $conf->{channel}, $text);
            } else {
                $heap->{ircd}->yield(daemon_cmd_privmsg => $name, $conf->{channel}, $text);
            }
        }

        $heap->{previous_recent} = $ret;

    } else {
        $heap->{previous_recent} = [];
    }

    $kernel->delay('delay_nowa_recent', $heap->{config}->{nowa}->{retry});
}

sub nowa_channel_recent_success {
    my($kernel, $heap, $ret) = @_[KERNEL, HEAP, ARG0];
    my $conf = $heap->{config}->{irc};

    msg "nowa_channel_recent_success";

    if (scalar(@$ret)) {
        my %prev = map { $_->{permalink} => 1 } @{ $heap->{previous_channel_recent} };

        for my $line (reverse @{ $ret }) {
            next if $prev{ $line->{permalink} };

            my $name = $line->{user};
            my $text = $line->{body};
            my $channel = $line->{channel};

            next unless $heap->{bot_joined_channel}->{$channel};

            unless ($heap->{channel_nicknames}->{$channel}->{$name}) {
                $heap->{ircd}->yield(add_spoofed_nick => { nick => $name });
                $heap->{ircd}->yield(daemon_cmd_join => $name, $channel);
                $heap->{channel_nicknames}->{$channel}->{$name} = 1;
            }

            if ($heap->{config}->{nowa}->{nowa_id} eq $name) {
warn "yield topic";
                $heap->{ircd}->yield(daemon_cmd_topic => $conf->{botname}, $channel, $text);
            } else {
warn "yield privmsg";
                $heap->{ircd}->yield(daemon_cmd_privmsg => $name, $channel, $text);
            }
        }

        $heap->{previous_channel_recent} = $ret;
    }

    $kernel->delay('delay_nowa_channel_recent', $heap->{config}->{nowa}->{retry});
}

sub ircd_default {
    my ($event, $args) = @_[ARG0 .. ARG1];

    use YAML;
    warn Dump [$event, $args];
}
