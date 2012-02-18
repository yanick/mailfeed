package App::MailFeed;

use 5.10.0;

use strict;
use warnings;

use YAML::Syck qw/ LoadFile /;
use Method::Signatures;
use LWP::Simple qw/ head /;
use XML::Feed;
use CHI;
use URI;
use Email::MIME;
use Email::LocalDelivery;

use Moose;

with qw/
    MooseX::Role::Loggable
    MooseX::ConfigFromFile 
/;

has feeds => (
    traits  => ['Array'],
    is => 'ro',
    handles => {
        all_feeds => 'elements',
    },
);

has '+log_to_stdout' => (
    lazy => 1,
    default => sub {
        $_[0]->debug,
    },
);

has app_dir => (
    is => 'ro',
    required => 1,
);

has cache => (
    lazy => 1,
    default => sub {
        CHI->new( 
            driver => 'BerkeleyDB',
            root_dir => $_[0]->app_dir,
        );
    },
    handles => {
        set_cache => 'set',
        cached => 'get',
    },
);

sub get_config_from_file {
    my ($class, $file) = @_;

    return LoadFile( $file );
}

method import_feed( $name, $url ) {
    $self->log_debug( "importing feed $name" );

    my $feed_key = "feed:$url";

    my $feed_modified = $self->feed_last_modified( $url );

    if( my $last_cache = $self->cached($feed_key) ) {
        if( $last_cache == $feed_modified ) {
            $self->log_debug( "feed hasn't been updated, skipping" );
            return;
        }
    }

    my $feed = XML::Feed->parse( URI->new($url ) ) or do {
        $self->log_debug( "couldn't parse feed at '$url'" );
        return;
    };

    $self->import_feed_entry( $name => $_ ) for $feed->entries;

    $self->set_cache( $feed_key => $feed_modified ) if $feed_modified;
}

method feed_last_modified( $url ) { (head($url))[2] }

method import_feeds {
    $self->import_feed( %$_ ) for $self->all_feeds;
}

method import_feed_entry ( $name, $entry ) {
    $self->log_debug( "processing " . $entry->title );

    my $link = $entry->link;

    if( $self->cached( $link ) ) {
        $self->log_debug( "entry already seen, skipping" );
        return;
    }

    my $email = $self->entry_to_email( $entry );

    Email::LocalDelivery->deliver( $email => $name );

    $self->set_cache( $link => time );
}

method entry_to_email( $entry ) {
    my $link = $entry->link;
    
    $link = "<a href='$link'>$link</a><br/><br/>" 
        if $entry->content->type eq 'text/html';

    return Email::MIME->create(
        header => [
            From    => sprintf( 'dummy@foo.org <%s>', $entry->author || ''),
            To      => 'dummy@foo.org',
            Subject => $entry->title,
            ],
            parts => [
                Email::MIME->create(
                    attributes => { content_type => $entry->content->type },
                    body => join "\n\n", $link, $entry->content->body,
                ),
            ],
    )->as_string;
}

App::MailFeed->meta->make_immutable;

1;

package main;

my $mailfeed = App::MailFeed->new_with_config(
    configfile => shift,
    debug => 1,
);

$mailfeed->import_feeds;

