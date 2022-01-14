#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Digest::SHA qw(sha1_hex);

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

my $o = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);

## Make sure SCRIPT commands are available
eval { $o->script_flush };
if ($@ && $@ =~ /ERR unknown command 'SCRIPT',/) {
  $c->();
  $t->();
  plan skip_all => 'This redis-server lacks scripting support';
}


## Commands related to Lua scripting

# Specifically, these commands test multi-word commands
ok($o->set(foo => 'bar'), 'set foo => bar');

my $script     = "return 1";
my $script_sha = sha1_hex($script);
my @ret        = $o->script_exists($script_sha);
ok(@ret && $ret[0] == 0, "script exists returns false");
@ret = $o->script_load($script);
ok(@ret && $ret[0] eq $script_sha, "script load returns the sha1 of the script");
ok($o->script_exists($script_sha), "script exists returns true after loading");
ok($o->evalsha($script_sha, 0), "evalsha returns true with the sha1 of the script");
ok($o->eval($script, 0), "eval returns true");

## All done
done_testing();
