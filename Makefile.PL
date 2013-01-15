
use strict;
use warnings;

use 5.008;

use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Perl binding for Redis database",
  "AUTHOR" => "Pedro Melo <melo\@cpan.org>",
  "BUILD_REQUIRES" => {
    "Digest::SHA" => 0,
    "IO::String" => 0,
    "IPC::Cmd" => 0,
    "Test::Deep" => 0,
    "Test::Exception" => 0,
    "Test::Fatal" => 0,
    "Test::More" => "0.98"
  },
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "Redis",
  "EXE_FILES" => [],
  "LICENSE" => "artistic_2",
  "NAME" => "Redis",
  "PREREQ_PM" => {
    "Try::Tiny" => 0
  },
  "VERSION" => "1.958",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



