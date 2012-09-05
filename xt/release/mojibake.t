#!perl

use Test::More;

eval 'use Test::Mojibake';
plan skip_all => 'Test::Mojibake required for source encoding testing'
    if $@;

all_files_encoding_ok();
