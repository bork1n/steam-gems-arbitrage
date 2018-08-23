package SGA::Storage;

use strict;
use warnings;

use Data::Dumper;
use Future::Mojo;
use JSON;
use Mojo::Redis2;
use Paws::Net::MojoAsyncCaller;
use Paws;
use Try::Tiny;

my $d = Paws->service(
    'DynamoDB',
    region => 'eu-west-1',

    caller => Paws::Net::MojoAsyncCaller->new(),
);

my $cache = {};
my $redis = Mojo::Redis2->new;
my $json  = JSON->new;

sub get_item {
    my $key     = shift;
    my $max_age = shift;

    return Future->wrap( $cache->{$key} ) if $cache->{$key};
    my $rd = $redis->get("cache/$key");
    my $f;
    if ($rd) {

        $f = Future->wrap( $json->decode($rd), 1 );
    }
    else {
        $f = $d->GetItem(
            TableName => 'cache',
            Key       => { key => { S => $key } }

        )->then(
            sub {
                my ($r) = @_;
                return Future->fail() unless $r->Item;
                my $item = $r->Item->Map;
                my $hash = { map { $_ => $item->{$_}->{S} } keys %$item };
                return Future->done( $hash, 0 );
            }
        );
    }

    #     warn "getting2 $key...\n";

    return $f->then(
        sub {
            my $hash       = shift;
            my $from_redis = shift;

            #            warn "$key $from_redis";
            #            warn "$key", Dumper($hash);
            if ( $max_age and time - $hash->{changed} > $max_age ) {

                #            warn 'failed';
                return Future::Mojo->fail($hash);
            }
            $cache->{$key} = $hash;
            $redis->set( "cache/$key" => $json->encode($hash) )
              unless $from_redis;
            return Future->done($hash);
        },
        sub {
            #            warn "$key failed";
            Future->fail( {} );
        }
    );
}

sub set_item {
    my ( $key, $data ) = @_;

    #    warn "saving $key...\n";
    $cache->{$key} = $data;
    $redis->set( "cache/$key" => $json->encode($data) );

    my $r = $d->PutItem(
        TableName => 'cache',
        Item      => {
            key => { S => $key },
            map { $_ => { S => $data->{$_} } } keys %$data
        }
    );
    return $r;
}

1;
