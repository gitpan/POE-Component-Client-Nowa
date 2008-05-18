use inc::Module::Install;
name 'POE-Component-Client-Nowa';
all_from 'lib/POE/Component/Client/Nowa.pm';

requires 'FindBin';
requires 'Getopt::Long';
requires 'POE';
requires 'POE::Component::Server::IRC';
requires 'POE::Component::TSTP';
requires 'WebService::Nowa';
requires 'YAML';

auto_include;
WriteAll;
