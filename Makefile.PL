use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME          => 'Redis',
  AUTHOR        => 'Pedro Melo <melo@simplicidade.org>',
  VERSION_FROM  => 'lib/Redis.pm',
  ABSTRACT_FROM => 'lib/Redis.pm',
  PL_FILES      => {},
  PREREQ_PM     => {
    'Carp'             => 0,
    'Data::Dumper'     => 0,
    'Encode'           => 0,
    'Fcntl'            => 0,
    'IO::Handle'       => 0,
    'IO::Select'       => 0,
    'IO::Socket::INET' => 0,
    'IO::String'       => 0,
    'Test::Deep'       => 0,
    'Test::Exception'  => 0,
    'Test::More'       => 0.92,
    'Tie::Hash'        => 0,
  },
  dist  => {COMPRESS => 'gzip -9f', SUFFIX => 'gz'},
  clean => {FILES    => 'Redis-*'},
);
