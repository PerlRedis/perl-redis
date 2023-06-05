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
  $o->scan_callback(sub { push @trace, $_ });

  is_deeply( [sort @trace], [sort keys %vals], 'all keys scanned once' );
};

subtest 'scan with pattern' => sub {
  my @trace;
  $o->scan_callback('ba*', sub { push @trace, $_ });

  is_deeply( [sort @trace], [sort qw[bar baz]], 'only selected keys scanned once' );
};


done_testing;
