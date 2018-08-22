package Fetcher;
use strict;
use warnings;

use local::lib;
use Data::Dumper;
use Future::Mojo;
use Future::Utils qw/try_repeat_until_success/;
use JSON;
use Mojo::DOM;
use Mojo::IOLoop::Subprocess;
use Moose;
use Paws;
use Try::Tiny;
require Storage;

use constant REST_TIME => 90;
my $user_agent =
'Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2214.85 Safari/537.36';

has gp_start => (
    is      => 'ro',
    default => 1,
);
has gp_count => (
    is      => 'ro',
    default => 150,
);
has gp_current => (
    is      => 'rw',
    lazy    => 1,
    isa     => 'Int',
    builder => '_build_gp_current',
    traits  => ['Counter'],
    handles => {
        inc_gp_current => 'inc',
    }
);
has gp_lambda_region => (
    is      => 'ro',
    default => 'us-west-1',
);
has gp_lambda => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_gp_lambda',
);
has qw/sleeps/ => ( is => 'rw', default => sub { return {} }, );
has [qw/downloaded calls failed_calls/] => ( is => 'rw', default => 0 );

sub _build_gp_current {
    my $self = shift;
    $self->gp_current( int( rand( $self->gp_count ) ) + $self->gp_start );
}

sub _build_gp_lambda {
    my $self = shift;
    $self->gp_lambda(
        Paws->service(
            'Lambda',
            region => $self->gp_lambda_region,

            caller => Paws::Net::MojoAsyncCaller->new(),
        )
    );
}

sub get_status {
    my $self = shift;
    my @b =
      grep { $self->sleeps->{$_} and $self->sleeps->{$_} > time }
      keys %{ $self->sleeps };
    return {
        p_total      => $self->gp_count,
        p_blocked    => @b + 0,
        downloaded   => $self->downloaded,
        calls        => $self->calls,
        failed_calls => $self->failed_calls,
    };
}

sub get_rur_price {
    my $self    = shift;
    my $item_id = shift;

    return $self->do_get(
        {
            url =>
"https://steamcommunity.com/market/itemordershistogram?country=RU&language=russian&currency=5&item_nameid=$item_id&two_factor=0",
            json        => 1,
            check_retry => sub {
                my $js = shift;
                if ( keys %$js == 1 and $js->{success} ) {
                    warn "get_rur_price success $js->{success}, regetting\n";
                    return 1;
                }
                return 0;
            },
        }
    )->then(
        sub {
            my $js    = shift;
            my $price = $js->{lowest_sell_order};
            warn Dumper($js) unless $price;
            return Future->done($price);
        }
    );
}

sub get_exchange_rate {
    my $self = shift;
    my $text =
      $self->do_get( { url => 'http://steam.steamlytics.xyz/currencies' } );
    my $dom  = Mojo::DOM->new( $text->get() );
    my $data = $dom->find('div.card-panel div table tr');
    my %codes;
    my $rates = {};
    $data    #
      ->map( sub { s/\<[^\<\>]+\>//rg } )    # remove htmls
      ->map( sub { s/\s+/,/rg } )            # remove whitespaces
      ->map( sub { s/\([^\(\)]*\)//rg } )    # remove codes
      ->map(
        sub {
            my ( undef, @l ) = split /,/, shift;
            unless (%codes) {
                my $c = 0;
                %codes = map { $c++ => $_ } @l;
            }
            else {
                my ( $currency, @r ) = @l;
                defined( $codes{$_} )
                  and $rates->{$currency}{ $codes{$_} } = $r[$_] + 0
                  for ( 0 .. scalar @r );
            }
        }
      );
    return $rates;
}

sub get_search_results {
    my $self  = shift;
    my $query = shift;
    my $html  = $self->do_get(
        {
            url => 'https://steamcommunity.com/market/search/render/?query='
              . $query,
            json        => 1,
            check_retry => sub {
                my $js = shift;
                if ( not %$js or not $js->{results_html} ) {
                    warn "seacrh/rednder, redo:" . Dumper($js);
                    return 1;
                }
                return 0;
            },
        }
    );
    return $html;
}

sub do_get_market_itemid {
    my $self = shift;
    my $l    = shift;

    $l =~ /listings\/([^\?]+)/;
    my $key = $1;

    return Storage::get_item( 'id/' . $key )->then(
        sub {
            my $v = shift;
            return Future->done( $v->{value} );
        },
        sub {
            return $self->do_get(
                {
                    url         => $l,
                    json        => 0,
                    check_retry => sub {
                        my $t = shift;
                        return 1 unless $t;
                        $t =~ /Market_LoadOrderSpread\(\s*(\d+)\s*\)/;
                        my $id = $1;
                        warn "no itemid for $key" unless $id;
                        return 1 unless $id;
                        return 0;
                    },
                }
            )->then(
                sub {
                    shift =~ /Market_LoadOrderSpread\(\s*(\d+)\s*\)/;
                    my $id = $1;
                    return Storage::set_item( 'id/' . $key,
                        { value => $id, updated => time } )
                      ->then( sub { return Future->done($id) } )
                      if $id;
                    return Future->done('');
                }
            );
        }
    );

}

sub do_get_gp {
    my $self = shift;
    my $gp;
    my $tries = 0;
    do {
        $self->inc_gp_current;
        $tries++;
        if ( $tries == $self->gp_count ) {
            return;
        }
        my $gpt =
          "gp-" . ( $self->gp_current % $self->gp_count + $self->gp_start );
        $gp = $gpt
          unless $self->sleeps->{$gpt} and $self->sleeps->{$gpt} > time;
    } while ( not $gp );
    return $gp;
}

sub do_get {
    my $self = shift;
    my $args = shift;
    my ( $url, $json, $check_retry ) =
      @{$args}{qw/url json check_retry/};
    my $js = new JSON;
    my $pl =
      $js->encode(
        { headers => { 'X-Query' => $url, 'X-UA' => $user_agent } } );
    return try_repeat_until_success {
        my $gp = $self->do_get_gp;
        unless ($gp) {
            my $f     = Future::Mojo->new;
            my $timer = 10 + rand(10);
            Mojo::IOLoop->timer(
                $timer => sub {
                    $f->fail('timer');
                }
            );
            return $f;
        }
        return $self->gp_lambda->Invoke(
            FunctionName => $gp,
            Payload      => $pl,
        )->then(
            sub {
                my $d = shift;
                my $res;
                try {
                    $self->downloaded(
                        $self->downloaded + length( $d->Payload ) );
                    $self->calls( $self->calls + 1 );
                    $res = $js->decode( $d->Payload );
                    if ( defined( $res->{errorMessage} ) ) {
                        my $err =
                          $res->{errorMessage} =~
                          /(Too Many requests|HTTP Error 403)/i
                          ? undef
                          : $res->{errorMessage};
                        warn "$gp failed $res->{errorMessage}\n" if $err;
                        $res = undef;
                    }
                    else {
                        $res = $res->{body};
                        $res = $js->decode($res) if $json;
                    }
                }
                catch {
                    warn "$_, $res, $d" . Dumper($d);
                    $res = undef;
                };
                if ( not $res
                    or ( $check_retry and $check_retry->($res) ) )
                {

                    $self->sleeps->{$gp} = time + REST_TIME;
                    return Future->fail('');
                }
                Future->done($res);
            },
            sub {
                warn "Calling lambda failed, retrying\n";
                Future->fail();
            }
        )->else(
            sub {
                $self->failed_calls( $self->failed_calls + 1 );
            }
        );
    }
}

1;
