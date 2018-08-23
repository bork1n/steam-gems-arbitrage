package SGA::Game;

use strict;
use warnings;

use Moo;
use Future::Mojo;
use SGA::Storage;

has [qw/id item_name fetcher forceupdate/] => ( is => 'rw' );
has gems => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_gems',
);
has cachetime => (
    is      => 'rw',
    default => 3 * 86400,
);
my $work = {};

sub _build_gems {
    my $self = shift;
    my $key  = 'games/' . $self->id;
    return $work->{$key} if $work->{$key};
    my $f = SGA::Storage::get_item( 'games/' . $self->id, $self->cachetime )->else(
        sub {
            my $old_data = shift;
            unless ( ref($old_data) ) {
                warn $old_data;
                $old_data = {};
            }
            my $old_gems = $old_data->{gems} // -1;

            my $name = $self->item_name;
            return Future->fail("doesn't exist row") unless $name;
            $name =~ s/ (Uncommon|Rare) (Profile Background|Smile|Emoticon)//g;
            $name =~ s/ (Profile Background|Smile|Emoticon)//g;

            my $cache = { name => $name, gems => $old_gems };
            return $self->update_goo($cache)->then(
                sub {
                    return Future->done($cache);
                }
            );
        }
    )->then(
        sub {
            my $data = shift;
            delete $work->{$key};
            return Future->done( $data->{gems} );
        }
    );
    $work->{$key} = $f;
    return $f;
}

sub update_goo {
    my $self  = shift;
    my $data  = shift;
    my $id    = $self->id;
    my $debug = shift // 1;

#   7 - uncommon smile,
# 4 - smile
# 4,6,8 - card
# 9 - common smile
# 10 rare background
#    12- background, smile
# 13 common smile
# 15 common smile
# 16 common smile
#warn 'fetching...';
    my $r = $self->fetcher->do_get(
        {
            url =>
"https://steamcommunity.com/auction/ajaxgetgoovalueforitemtype/?appid=$id&item_type=12",
            json => 1,
        }
    )->then(
        sub {
            my $r = shift;
            if ( $data->{gems} != $r->{goo_value} ) {
                print "$data->{name}: $data->{gems} -> $r->{goo_value}\n"
                  if $debug;
                $data->{gems} = $r->{goo_value};
            }
            $data->{changed} = time;
            return SGA::Storage::set_item( 'games/' . $id, $data );
        }
    );

    return $r;
}

1;
