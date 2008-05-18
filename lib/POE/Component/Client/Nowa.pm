package POE::Component::Client::Nowa;

use strict;
use warnings;

our $VERSION = '0.01';

use base qw/Class::Accessor::Fast/;

__PACKAGE__->mk_accessors(qw/nowa/);

use POE;
use WebService::Nowa;

sub spawn {
    my($class, %args) = @_;

    my $self = bless {}, $class;

    $self->{session_id} = POE::Session->create(
        object_states => [
            $self => {
                map { $_ => "poe_$_" } qw/_start _stop register unregister _unregister notify attach update recent channels channel_recent/
            },
        ],
        args => [ \%args ],
        heap => { args => \%args },
    )->ID;

    $self;
}

sub session_id { $_[0]->{session_id} }

sub yield {
    my $self = shift;
    $poe_kernel->post($self->session_id, @_);
}

sub poe_notify {
    my($kernel, $heap, $name, $args) = @_[KERNEL, HEAP, ARG0, ARG1];
    $kernel->post($_ => "nowa.$name" => $args) for keys %{$heap->{listeners}};
}

sub poe__start {
    my ($self, $kernel, $heap, $args) = @_[OBJECT, KERNEL, HEAP, ARG0];

    $kernel->alias_set('nowa');

    $heap->{nowa} = WebService::Nowa->new({
            nowa_id  => $heap->{args}->{nowa_id},
            password => $heap->{args}->{password},
            api_pass => $heap->{args}->{api_pass},
        });

    $kernel->yield('attach');
}

sub poe__stop {}

sub poe_register {
    my($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
    $kernel->refcount_increment($sender->ID, __PACKAGE__);
    $heap->{listeners}->{$sender->ID} = 1;
    $kernel->post($sender->ID => "registered" => $_[SESSION]->ID);
}


sub poe_unregister {
    my($kernel, $heap, $sender) = @_[KERNEL, HEAP, SENDER];
    $kernel->yield(_unregister => $sender->ID);
}

sub poe__unregister {
    my($kernel, $heap, $session) = @_[KERNEL, HEAP, ARG0];
    $kernel->refcount_decrement($session, __PACKAGE__);
    delete $heap->{listeners}->{$session};
}


sub poe_attach {
    my ($kernel, $heap, $args) = @_[KERNEL, HEAP, ARG0];

#    $kernel->delay( attach => 1 );
}

sub poe_update {
    my ($self, $kernel, $heap, $message) = @_[OBJECT, KERNEL, HEAP, ARG0];
    $heap->{nowa}->update_nanishiteru($message);
}

sub poe_recent {
    my ($self, $kernel, $heap, $target, $message) = @_[OBJECT, KERNEL, HEAP];

    my $data = $heap->{nowa}->recent;
    $kernel->yield(notify => 'recent_success', $data);
}

sub poe_channels {
    my ($self, $kernel, $heap, $target, $message) = @_[OBJECT, KERNEL, HEAP];

    my $data = $heap->{nowa}->channels;
    $kernel->yield(notify => 'channels_success', $data);
}

sub poe_channel_recent {
    my ($self, $kernel, $heap, $target, $message) = @_[OBJECT, KERNEL, HEAP];

    my $data = $heap->{nowa}->channel_recent;
    $kernel->yield(notify => 'channel_recent_success', $data);
}

1;
__END__

=head1 NAME

POE::Component::Client::Nowa - POE Client of the Nowa

=head1 SYNOPSIS

  use POE::Component::Client::Nowa;
  # see bin/nowa2ircd.pl for IRCD example

=head1 DESCRIPTION

POE::Component::Client::Nowa is POE Client of the Nowa.

Nowa is the community service run by L<http://www.livedoor.com/> in Japan. See L<http://nowa.jp/>

=head1 AUTHOR

woremacx E<lt>woremacx at cpan dot orgE<gt>

=head1 REPOSITORY

  svn co http://svn.coderepos.org/share/lang/perl/POE-Component-Client-Nowa/

The repository of POE::Component::Client::Nowa is hosted by L<http://coderepos.org/share/>.
Patches and collaborators are welcome.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<http://nowa.jp/>,
L<WebService::Nowa>,
L<POE::Component::Client::Twitter>

=cut
