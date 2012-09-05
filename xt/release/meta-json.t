#!perl

use Test::More;
eval 'use Test::CPAN::Meta::JSON';
plan skip_all => 'Test::CPAN::Meta::JSON required for testing META.json' if $@;
meta_json_ok();
