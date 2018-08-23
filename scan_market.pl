#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib $FindBin::Bin. '/lib';

use Data::Dumper;
use Future::Utils qw/fmap_concat/;

use SGA::Game;
use SGA::Fetcher;

my $fetcher = SGA::Fetcher->new( gp_start => 1, gp_count => 250 );

use constant {
    STEAM_COMISSION => 0.13,
    PER_PAGE        => 100,
    INTEREST        => 0.10,    # at least 10% interest
    GAME            => 'any',
};

my $gems_price_1k = $fetcher->get_rur_price(
    $fetcher->do_get_market_itemid(
        'https://steamcommunity.com/market/listings/753/753-Sack%20of%20Gems')
      ->get()
)->get() / 100;
warn "price for sack of gems: $gems_price_1k rur\n";
my $prices;
my $USDRUR = $ARGV[0] || $fetcher->get_exchange_rate()->{USD}->{RUB};
print "Rate: $USDRUR\n";

my $page_from = $ARGV[1] || 0;
my $page_to = $page_from + 1;

for ( 1 .. 100 ) {
    $prices->{$_} = sprintf "%0.2f",
      int( $gems_price_1k / 1000 * $_ / $USDRUR * 100 + 1 ) / 100;
}

$| = 1;
print "\n";
my $init = 1;
my $stop_working;
my $total_items = 1;
my ( $total, $base, $rur ) = ( 0, 0, 0 );
my $notified = {};

sub show_status {
    my $h    = $fetcher->get_status();
    my $page = $total / PER_PAGE;
    printf
"Blocked: %3d/%d, %3.0f MB, %4d(%4d) calls, %5d/%5d/%4.1f\%\% items, page %4d,  passed: base:%4d, rur:%4d\n",
      $h->{p_blocked}, $h->{p_total}, $h->{downloaded} / 1024 / 1024,
      $h->{calls}, $h->{failed_calls}, $total, $total_items,
      $total / $total_items * 100, $page, $base, $rur;
    Mojo::IOLoop->timer( 200 => \&show_status );
}

show_status();
my $start = time;

#use Test::LeakTrace;
# leaktrace{
do_new();
print "Finished in: ", ( time - $start ), " seconds\n";

# };

sub do_new {
    my $init;
    my @l = ( $page_from .. 800 );
    my $f = fmap_concat {
        my $page = $_;
        $stop_working = 1 if $init and $page_to and $page > $page_to;

        return Future->done("stop_working(=$stop_working, $page>?$page_to)")
          if $stop_working;

        my $url =
            '&start='
          . ( $page * PER_PAGE )
          . '&count='
          . PER_PAGE
          . '&search_descriptions=0&sort_column=quantity&sort_dir=desc'
          . '&appid=753'
          . '&category_753_Game%5B%5D='
          . GAME
          . '&category_753_item_class%5B%5D=tag_item_class_4'    #smile
          . '&category_753_item_class%5B%5D=tag_item_class_3' #profile background

          #. '&category_753_item_class%5B%5D=tag_item_class_2' #card
          ;

        return $fetcher->get_search_results($url)->then(
            sub {
                my $html = shift;
                unless ($init) {
                    $init = 1;

                    #                    $html->{total_count} = 1000;
                    $total_items = $html->{total_count};
                    $page_to     = int( $html->{total_count} / PER_PAGE )
                      if $html->{total_count};
                }
                my $rows = parse_search_page($html);
                return process_results($rows);
            },
            sub {
                warn @_;
                return Future->done();
            }
        );
    }
    foreach => \@l, concurrent => 6;
    $f->get();
}

sub parse_search_page {
    my $html = shift;
    my @rows = split /market_listing_row_link" href="/, $html->{results_html};
    shift @rows;
    my $r = [];
    for my $row (@rows) {
        $row =~ /^(\S+)" id="resultlink_/;
        my $l = $1;
        $l =~ /753\/(\d+)/;
        my $game_id = $1;
        my $count   = 0;
        if ( $row =~ /market_listing_num_listings_qty"[^\>]*>([\d,]+)<\/span>/ )
        {
            $count = $1;
            $count =~ s/,//;
        }
        unless ( $row =~ /normal_price\"[^\>]*>\$([\d,\.]+) USD<\/span>/
            or $row =~ /normal_price\"[^\>]*>\$([\d,\.]+)<\/span>/ )
        {
            die "XX: Possible regex changed\n",
              $row;    # if $price !~ /^\d+$/ or $price>100;
        }
        my $price = $1;
        $price =~ s/,//g;

        unless ( $row =~ /market_listing_game_name"\>(.+)\<\/span/ ) {
            die "no game name in row";
        }
        my $name = $1;

        die "XX: Possible regex changed (price $price)\n", $row
          if $price !~ /^[0-9\.]+$/;
        push @$r,
          {
            qty     => $count,
            price   => $price,
            game_id => $game_id,
            link    => $l,
            name    => $name
          };
    }
    return $r;
}

sub process_results {
    my $rows  = shift;
    my $final = fmap_concat {
        my ( $count, $price, $game_id, $l, $name ) =
          @{$_}{qw/ qty price game_id link name /};
        unless ($count) {
            $stop_working = 1;
            return Future->done("0 count");
        }
        $total++;

        return SGA::Game->new(
            id        => $game_id,
            item_name => $name,
            fetcher   => $fetcher
        )->gems->then(
            sub {
                my $gems = shift;
                return Future->fail('basecheck')
                  if $price < 0.01 or $gems < 1;

                return Future->fail('basecheck')
                  if ( !defined( $prices->{$gems} )
                    || $price > $prices->{$gems}
                    || $gems / $price < 1000 );
                return Future->done($gems);
            }
        )->then(
            sub {
                my $gems = shift;
                $base++;
                return $fetcher->do_get_market_itemid($l)
                  ->then( sub { return Future->done( $gems, @_ ) } );
            }
        )->then(
            sub {
                my ( $gems, $itemid ) = @_;

                return $fetcher->get_rur_price($itemid)
                  ->then( sub { return Future->done( $gems, $itemid, @_ ) } );
            }
        )->then(
            sub {
                my ( $gems, $itemid, $rur_price ) = @_;
                $rur_price = sprintf '%.2f', $rur_price / 100;
                my $pile_price = $rur_price / $gems * 1000;
                my $pile_price_w_comission =
                  $pile_price / ( 1 - STEAM_COMISSION );
                return Future->fail('rurcheck')
                  if $pile_price_w_comission >
                  $gems_price_1k * ( 1 - INTEREST );
                return Future->done('duplicate')
                  if $notified->{ $l . $rur_price };
                $notified->{ $l . $rur_price } = 1;
                $rur++;
                print STDERR sprintf "*" x 80
                  . "\nrur+perc: %4.04f rur: %4.2f gems: %d %s\n"
                  . "*" x 80 . "\n",
                  $pile_price_w_comission,
                  $rur_price, $gems, $l;
                `notify-send 'FOUND for $pile_price_w_comission'`;
                return Future->done($rur_price);
            }
        )->else(
            sub {
                warn "failed with", @_
                  if $_[0] ne 'basecheck' and $_[0] ne 'rurcheck';
                return Future->done();
            }
        );
    }
    foreach => $rows, concurrent => 20;
    return $final;
}
