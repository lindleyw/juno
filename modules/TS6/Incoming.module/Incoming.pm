# Copyright (c) 2014, mitchellcooper
#
# Created on Mitchells-Mac-mini.local
# Fri Aug  8 22:47:08 EDT 2014
# Incoming.pm
#
# @name:            'TS6::Incoming'
# @package:         'M::TS6::Incoming'
# @description:     'basic set of TS6 command handlers'
#
# @depends.modules: 'TS6::Base'
#
# @author.name:     'Mitchell Cooper'
# @author.website:  'https://github.com/cooper'
#
package M::TS6::Incoming;

use warnings;
use strict;
use 5.010;

use M::TS6::Utils qw(uid_from_ts6 user_from_ts6 mode_from_prefix_ts6);

our ($api, $mod, $pool);

our %ts6_incoming_commands = (
    EUID => {
                   # :sid EUID      nick hopcount nick_ts umodes ident cloak ip  uid host act :realname
        params  => '-source(server) *    *        ts      *      *     *     *   *   *    *   :rest',
        code    => \&euid,
        #forward => 1
    },
    SJOIN => {
                  # :sid SJOIN     ch_time ch_name mode_str mode_params... :nicklist
        params => '-source(server) ts      *       *        @rest',
        code   => \&sjoin
        #forward => 1
    }
);

# EUID
#
# charybdis TS6
#
# capab         EUID
# source:       server
# parameters:   nickname, hopcount, nickTS, umodes, username, visible hostname,
#               IP address, UID, real hostname, account name, gecos
# propagation:  broadcast
#
# ts6-protocol.txt:315
#
sub euid {
    my ($server, $event, $source_serv, @rest) = @_;
    my %u = (
        server   => $source_serv,       # the actual server the user connects from
        source   => $server->{sid},     # SID of the server who told us about him
        location => $server             # nearest server we have a physical link to
    );
    $u{$_} = shift @rest foreach qw(
        nick ts6_dummy nick_time umodes ident
        cloak ip ts6_uid host account_name real
    );
    my ($mode_str, undef) = (delete $u{umodes}, delete $u{ts6_dummy});
    
    $u{time} = $u{nick_time};                   # for compatibility
    $u{host} = $u{cloak} if $u{host} eq '*';    # host equal to visible
    $u{uid}  = uid_from_ts6($u{ts6_uid});       # convert to juno UID

    # uid collision?
    if ($pool->lookup_user($u{uid})) {
        # can't tolerate this.
        # the server is bugged/mentally unstable.
        L("duplicate UID $u{uid}; dropping $$server{name}");
        $server->conn->done('UID collision') if $server->conn;
    }

    # nick collision!
    my $used = $pool->lookup_user_nick($u{nick});
    if ($used) {
        # TODO: this.
        return;
    }

    # create a new user with the given modes.
    my $user = $pool->new_user(%u);
    $user->handle_mode_string($mode_str, 1);

    return 1;

}

# SJOIN
#
# source:       server
# propagation:  broadcast
# parameters:   channelTS, channel, simple modes, opt. mode parameters..., nicklist
#
# ts6-protocol.txt:821
#
sub sjoin {
    my $nicklist = pop;
    my ($server, $event, $serv, $ts, $ch_name, $mode_str, @mode_params) = @_;

    # maybe we have a channel by this name, otherwise create one.
    my $channel = $pool->lookup_channel($ch_name) || $pool->new_channel(
        name => $ch_name,
        time => $ts
    );

    # store mode string before any possible changes.
    my @after_params;       # params after changes.
    my $after_modestr = ''; # mode string after changes.
    my $old_modestr   = $channel->mode_string_hidden($serv, 1); # all but status and lists
    my $old_s_modestr = $channel->mode_string_status($serv);    # status only
    
    # take the new time if it's less recent.
    my $old_time = $channel->{time};
    my $new_time = $channel->take_lower_time($ts, 1);
    my $accept_new_modes;
    
    # the channel TS changed (it was older).
    if ($new_time < $old_time) {
        # accept all new modes and propagate all simple modes, not just the difference.
        # wipe out our old modes. (already done)
        $accept_new_modes++;
    }

    # the TS is the same as ours.
    elsif ($ts == $old_time) {
        $accept_new_modes++;
    }
    
    # their time was bad (newer).
    else {
        # propagate only the users, not the modes.
        # ignore the modes and prefixes.
    }
print "NICKLIST: $nicklist\n";
    # handle the nick list.
    #
    # add users to channel.
    # determine prefix mode string.
    #
    my ($uids_modes, @uids) = '';
    foreach my $str (split /\s+/, $nicklist) {
        my ($prefixes, $uid) = ($str =~ m/^(\W*)([0-9A-Z]+)$/) or next;
        my $user     = user_from_ts6($uid) or next;
        my @prefixes = split //, $prefixes;

        # this user does not physically belong to this server.
        next if $user->{location} != $server;

        # join the new users.
        unless ($channel->has_user($user)) {
            $channel->cjoin($user, $channel->{time});
            $channel->sendfrom_all($user->full, "JOIN $$channel{name}");
            $channel->fire_event(user_joined => $user);
        }

        # no prefixes or not accepting the prefixes.
        next unless length $prefixes && $accept_new_modes;

        # determine the modes and add them to the mode string / parameters.
        my $modes    = join '', map { mode_from_prefix_ts6($server, $_) } @prefixes;
        $uids_modes .= $modes;
        push @uids, $uid for 1 .. length $modes;
        
    }
    
    # combine this with the other modes in the message.
    my $command_modestr = join(' ', '+'.$mode_str.$uids_modes, @mode_params, @uids);
    
    # okay, now we're ready to apply the modes.
    if ($accept_new_modes) {
    
        # determine the difference between
        # $old_modestr     (all former simple modes [no status, no lists])
        # $command_modestr (all new modes including status)
        my $difference = $serv->cmode_string_difference($old_modestr, $command_modestr, 1);
        
        # the command time took over, so we need to remove our current status modes.
        if ($new_time < $old_time) {
            substr($old_s_modestr, 0, 1) = '-';
            
            # separate each string into modes and params.
            my ($s_modes, @s_params) = split ' ', $old_s_modestr;
            my ($d_modes, @d_params) = split ' ', $difference;
            
            # combine.
            $s_modes  //= '';
            $d_modes  //= '';
            $difference = join(' ', join('', $d_modes, $s_modes), @d_params, @s_params);

        }
        
        # handle the mode string locally.
        $channel->do_mode_string_local($serv, $serv, $difference, 1, 1) if $difference;
        
    }
    
    return 1;
}

$mod
