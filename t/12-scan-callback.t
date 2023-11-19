#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

my $o;
is(
  exception { $o = Redis->new(server => $srv,
                              name => 'my_name_is_glorious',
                              ssl => $use_ssl,
                              SSL_verify_mode => 0) },
  undef, 'connected to our test redis-server',
);

my %vals = (
  foo => 1,
  bar => 2,
  baz => 3,
  quux => 4,
);

$o->set($_, $vals{$_}) for keys %vals;

subtest 'shotgun scan' => sub {
  my @trace;
  $o->scan_callback(sub { push @trace, $_[0] });

  is_deeply( [sort @trace], [sort keys %vals], 'all keys scanned once' );
};

subtest 'scan with pattern' => sub {
  my @trace;
  $o->scan_callback('ba*', sub { push @trace, $_[0] });

  is_deeply( [sort @trace], [sort qw[bar baz]], 'only selected keys scanned once' );
};

$o->hset( "hash", "foo", 42 );
$o->hset( "hash", "bar", 137 );

subtest 'shotgun hscan' => sub {
  my %copy;

  $o->hscan_callback( "hash", sub {
    my ($key, $value) = @_;
    $copy{$key} += $value;
  });

  is_deeply \%copy, { foo => 42, bar => 137 }, 'each key processed exactly once';
};

subtest 'hscan with pattern' => sub {
  my %copy;

  $o->hscan_callback( "hash", "ba*", sub {
    my ($key, $value) = @_;
    $copy{$key} += $value;
  });

  is_deeply \%copy, { bar => 137 }, 'only matching keys processed exactly once';
};


subtest 'sscan (iteration over set)' => sub {
  my @keys = qw( foo bar quux x:1 x:2 x:3 );
  my %set = map { $_ => 1 } @keys;
  my %restricted = map { $_ => 1 } grep { /^x:/ } @keys;

  $o->sadd( "zfc", @keys );

  {
    my %copy;
    $o->sscan_callback( "zfc", sub {
      my $entry = shift;
      $copy{$entry}++;
    });
    is_deeply \%copy, \%set, 'all values in set listed exactly once';
  };

  {
    my %copy;
    $o->sscan_callback( "zfc", "x:*", sub {
      my $entry = shift;
      $copy{$entry}++;
    });
    is_deeply \%copy, \%restricted, 'only matching values in set listed exactly once';
  };
};

done_testing;
