# Copyright (c) 2014, matthew
#
# Created on mattbook
# Thu Jun 26 22:26:14 EDT 2014
# SASL.pm
#
# @name:            'SASL'
# @package:         'M::SASL'
# @description:     'Provides SASL authentication'
#
# @depends.modules:  ['Base::Capabilities', 'Base::RegistrationCommands', 'Account']
#
# @author.name:     'Matthew Barksdale'
# @author.website:  'https://github.com/mattwb65'
#
package M::SASL;

use warnings;
use strict;
use 5.010;

use MIME::Base64;
use M::Account qw(verify_account login_account);

our ($api, $mod, $pool);

sub init {
    $mod->register_registration_command(
        name       => 'AUTHENTICATE',
        code       => \&rcmd_authenticate,
        paramaters => 1
    ) or return;
    $mod->register_capability('sasl');
    $pool->on('user.new' => \&user_new, with_eo => 1);
}

# Registration command: AUTHENTICATE
sub rcmd_authenticate {
    my ($connection, $event, $arg) = @_;
    $connection->early_reply(906, ':SASL authentication aborted') and return if $arg eq '*';
    $connection->early_reply(907, ':You have already authenticated using SASL') and return if $connection->{sasl};
    $connection->early_reply(908, 'PLAIN :are availiable SASL mechanisms') and return if uc $arg eq 'M';
    if (!exists $connection->{sasl_pending})
    {
        if (uc $arg ne 'PLAIN') {
            $connection->early_reply(904, ':SASL authentication failed');
            return;
         } else {
             $connection->send('AUTHENTICATE +');
             $connection->{sasl_pending} = 1;
         }
    } else {
        my (undef, $user, $password) = split('\0', decode_base64($arg));
        if (my $act = verify_account($user, $password)) {
            $connection->{sasl_account} = $act;
            $connection->{sasl} = 1;
            $connection->early_reply(900, "$$connection{nick}!$$connection{ident}\@$$connection{host} $$act{name} :You are now logged in as $$act{name}.");
            $connection->early_reply(903, ':SASL authentication successful');
            delete $connection->{sasl_pending};
        } else {
          $connection->early_reply(904, ':SASL authentication failed');
          return;
        }
    }
}

# user.new event
sub user_new {
    my ($user, $event) = @_;
    if ($user->{sasl_account}) {
        login_account(delete $user->{sasl_account}, $user, undef, undef, 1);
    }
}

$mod

