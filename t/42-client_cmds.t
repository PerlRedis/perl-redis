#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis(requires_version => '2.6.9');
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

subtest 'client_{set|get}name commands' => sub {
  ok(my $r = Redis->new(server => $srv,
                        ssl => $use_ssl,
                        SSL_verify_mode => 0), 'connected to our test redis-server');

  my @clients = $r->client_list;
  is(@clients, 1, 'one client listed');
  like($clients[0], qr/\s+name=\s+/, '... no name set yet');

  is($r->client_setname('my_preccccious'), 'OK',             "client_setname() is supported, no errors");
  is($r->client_getname,                   'my_preccccious', '... client_getname() returns new connection name');

  @clients = $r->client_list;
  like($clients[0], qr/\s+name=my_preccccious\s+/, '... no name set yet');
};


subtest 'client name via constructor' => sub {
  ok(my $r = Redis->new(server => $srv,
                        name => 'buuu',
                        ssl => $use_ssl,
                        SSL_verify_mode => 0), 'connected to our test redis-server, with a name');
  is($r->client_getname, 'buuu', '...... name was properly set');

  ok($r = Redis->new(server => $srv,
                     name => sub {"cache-for-$$"},
                     ssl => $use_ssl,
                     SSL_verify_mode => 0), '... with a dynamic name');
  is($r->client_getname, "cache-for-$$", '...... name was properly set');

  ok($r = Redis->new(server => $srv,
                     name => sub {undef},
                     ssl => $use_ssl,
                     SSL_verify_mode => 0), '... with a dynamic name, but returning undef');
  is($r->client_getname, undef, '...... name was not set');

  my $generation = 0;
  for (1 .. 3) {
    ok($r = Redis->new(server => $srv,
                       name => sub { "gen-$$-" . ++$generation },
                       ssl => $use_ssl, SSL_verify_mode => 0),
      "Using dynamic name, for generation $generation");
    my $n = "gen-$$-$generation";
    is($r->client_getname, $n, "... name was set properly, '$n'");
  }
};


done_testing();
