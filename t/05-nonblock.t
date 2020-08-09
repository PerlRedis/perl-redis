#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv, undef, undef, undef, undef, undef, $sock_temp_file) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

subtest 'non-block TCP' => sub {
  ok(my $r = Redis->new(server => $srv,
                        ssl => $use_ssl,
                        SSL_verify_mode => 0), 'connected to our test redis-server via TCP');

  ## Try to read from server (nothing sent, so nothing to read)
  ## But kill if we block
  local $SIG{ALRM} = sub { kill 9, $$ };
  alarm(2);
  ok(!$r->__try_read_sock($r->{sock}), "Nothing to read, didn't block");
  alarm(0);
};


subtest 'non-block UNIX' => sub {
  ok(my $r = Redis->new(sock => $sock_temp_file), 'connected to our test redis-server via UNIX');

  ## Try to read from server (nothing sent, so nothing to read)
  ## But kill if we block
  local $SIG{ALRM} = sub { kill 9, $$ };
  alarm(2);
  ok(!$r->__try_read_sock($r->{sock}), "Nothing to read, didn't block");
  alarm(0);
};


done_testing();
