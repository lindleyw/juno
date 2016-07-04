# Copyright (c) 2009-14, Mitchell Cooper
#
# @name:            "Core::ChannelModes"
# @version:         ircd->VERSION
# @package:         "M::Core::ChannelModes"
# @description:     "the core set of channel modes"
#
# @depends.modules: ['Base::ChannelModes', 'Base::Capabilities']
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package M::Core::ChannelModes;

use warnings;
use strict;
use 5.010;

our ($api, $mod, $me, $pool);

our %channel_modes = (

    # simple modes
    no_ext        => { type => 'normal' },
    protect_topic => { type => 'normal' },
    moderated     => { type => 'normal' },

    # banlike modes
    ban => {
        type  => 'banlike',
        list  => 'ban',
        reply => 'ban'
    },
    except => {
        type  => 'banlike',
        list  => 'except',
        reply => 'except'
    }

);

sub init {

    # register status channel modes.
    register_statuses($_) or return foreach
        sort { $b <=> $a } keys %ircd::channel_mode_prefixes;

    # add multi-prefix capability.
    $mod->register_capability('multi-prefix');

    # add channel message restrictions.
    add_message_restrictions();

    return 1;
}

########################
# STATUS CHANNEL MODES #
########################

# status modes
sub register_statuses {
    my $level = shift;
    my $name  = $ircd::channel_mode_prefixes{$level}[2];
    $mod->register_channel_mode_block( name => $name, code => sub {
        my ($channel, $mode) = @_;
        my $source = $mode->{source};

        # find the target.
        my $t_user = $mode->{user_lookup}($mode->{param});

        # make sure the target user exists.
        if (!$t_user) {
            $source->numeric(ERR_NOSUCHNICK => $mode->{param})
                if $source->isa('user') && $source->is_local;
            return;
        }

        # and also make sure he is on the channel
        if (!$channel->has_user($t_user)) {
            $source->numeric(ERR_USERNOTINCHANNEL => $t_user->{nick}, $channel->name)
                if $source->isa('user') && $source->is_local;
            return;
        }

        if (!$mode->{force} && $source->is_local) {
            my $check1 = sub {

                # no basic status
                return unless $channel->user_has_basic_status($source);

                # he has a higher status..
                return 1 if $mode->{state};
                return if $channel->user_get_highest_level($source) <
                          $channel->user_get_highest_level($t_user);

                return 1;
            };

            my $check2 = sub {

                # the source's highest status is not enough.
                return if $channel->user_get_highest_level($source) < $level;

                return 1;
            };

            # the above test(s) failed
            if (!&$check1 || !&$check2) {
                $mode->{send_no_privs} = 1;
                return;
            }

        }

        # [USER RESPONSE, SERVER RESPONSE]
        $mode->{param} = [ $t_user->{nick}, $t_user->{uid} ];

        # add or remove from the list.
        my $do = $mode->{state} ? 'add_to_list' : 'remove_from_list';
        $channel->$do($name, $t_user);

        return 1;

    }) or return;

    return 1
}

sub add_message_restrictions {

    # not in channel and no external messages?
    $pool->on('user.can_message' => sub {
        my ($user, $event, $channel, $message, $type) = @_;

        # not internal only, or user is in channel.
        return unless $channel->is_mode('no_ext');
        return if $channel->has_user($user);

        # no external messages.
        $user->numeric(ERR_CANNOTSENDTOCHAN => $channel->name, 'No external messages');
        $event->stop('no_ext');

    }, name => 'no.external.messages', with_eo => 1, priority => 30);

    # moderation and no voice?
    $pool->on('user.can_message' => sub {
        my ($user, $event, $channel, $message, $type) = @_;

        # not moderated, or the user has proper status.
        return unless $channel->is_mode('moderated');
        return if $channel->user_get_highest_level($user) >= -2;

        # no external messages.
        $user->numeric(ERR_CANNOTSENDTOCHAN => $channel->name, 'Channel is moderated');
        $event->stop('moderated');

    }, name => 'moderated', with_eo => 1, priority => 20);

    # banned and no voice?
    $pool->on('user.can_message' => sub {
        my ($user, $event, $channel, $message, $type) = @_;

        # not banned, or the user has overriding status.
        return if $channel->user_get_highest_level($user) >= -2;
        return unless $channel->list_matches('ban', $user);
        return if $channel->list_matches('except', $user);

        $user->numeric(ERR_CANNOTSENDTOCHAN => $channel->name, "You're banned");
        $event->stop('banned');

    }, name => 'stop.banned.users', with_eo => 1, priority => 10);

}

$mod
