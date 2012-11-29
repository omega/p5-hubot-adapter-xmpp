package Hubot::Adapter::XMPP;

use Moose;
use namespace::autoclean;

extends 'Hubot::Adapter';
use 5.010;

use AnyEvent;
use AnyEvent::XMPP::Client;
use AnyEvent::XMPP::Ext::Disco;
use AnyEvent::XMPP::Ext::MUC;

use Hubot::Message;

has robot => (is => 'ro', isa => 'Hubot::Robot');
has cv => (is => 'ro', lazy => 1, builder => '_build_cv');
sub _build_cv { return AnyEvent->condvar; }
has xmpp => (is => 'ro', lazy => 1, builder => '_build_xmpp');
sub _build_xmpp {
    my $self = shift;
    my $cl = AnyEvent::XMPP::Client->new( debug => $ENV{HUBOT_XMPP_DEBUG} // 0 );
    $cl->add_extension($self->disco);
    $cl;
}
has disco => (is => 'ro', lazy => 1, builder => '_build_disco');
sub _build_disco { AnyEvent::XMPP::Ext::Disco->new };

has 'presence' => (is => 'ro', lazy => 1, builder => '_build_presence');
sub _build_presence {
    my $self = shift;
    my $pres = $self->xmpp->get_ext('Presence');
    $pres->set_default('available', "I'm just a friendly bot");
    return $pres;
}

has muc => (is => 'rw');

sub send {
    my ($self, $user, @strings) = @_;
    my $con = $self->xmpp->find_account_for_dest_jid( $user->{room} );
    my $room = $self->muc->get_room($con, $user->{room});
    for (@strings) {
        my $msg = $room->make_message();

        $msg->add_body($_);
        $msg->send;
    }
}

sub reply {
    my ($self, $user, @strings) = @_;
    @strings = map { $user->{name} . ": $_" } @strings;
    $self->send( $user, @strings );
}

sub run {
    my $self = shift;

    my %options = (
        nick => $ENV{HUBOT_XMPP_NICK} || $self->robot->name,

        #server => $ENV{HUBOT_XMPP_SERVER},
        jid => $ENV{HUBOT_XMPP_JID},
        password => $ENV{HUBOT_XMPP_PASSWORD},

        rooms => [ split(/,/, $ENV{HUBOT_XMPP_ROOMS} ) ],
    );

    $self->xmpp->add_account($options{jid}, $options{password});

    $self->xmpp->reg_cb(
        session_ready => sub {
            my ($xmpp, $acc) = @_;
            # Lets setup MUC then..
            my $muc = AnyEvent::XMPP::Ext::MUC->new( connection => $acc->connection, disco => $self->disco );
            $self->muc($muc); # XXX: mutable state :((

            $xmpp->add_extension($muc);
            $muc->join_room($acc->connection, $_, $options{nick},
                history => {
                    chars => 0,
                },

            ) foreach @{ $options{rooms} };

            $muc->reg_cb(
                message => sub {
                    my ($client, $room, $msg, $is_echo) = @_;
                    my $user = $self->createUser($room, $msg->from_nick);
                    return unless $user;
                    $user->{room} = $room->jid;
                    $self->receive(
                        Hubot::TextMessage->new(
                            user => $user,
                            text => $msg->any_body,
                        )
                    );
                },
                join => sub {
                    my ($client, $room, $user) = @_;
                    $user = $self->createUser($room, $user);
                    return unless $user;
                    $user->{room} = $room->jid;
                    $self->receive(
                        Hubot::EnterMessage->new( user => $user )
                    );
                },
            );
        },
        recv_message => sub {
        },
        connected => sub {
        },
        diconnected => sub {
        },
        message => sub {
            my ($xmpp, $acc, $msg) = @_;
            # Should send to stats tool here
        },
        error => sub {
            my ($xmpp, $acc, $err) = @_;
            say "ERROR: " . $err->string;
        },
    );

    $self->cv->begin;
    $self->emit('connected');
    $self->xmpp->start;
    $self->cv->recv;
}


sub createUser {
    my ($self, $room, $nick) = @_;
    return unless $nick;
    my $user = $self->userForName($nick);
    unless ($user) {
        my $id = lc($nick);
        $id =~ s/[^a-z]//g;
        $user = $self->userForId(
            $id,
            {
                name => $nick,
                room => $room->jid,
            }
        );
    }

    return $user;
}


__PACKAGE__->meta->make_immutable;
1;
