use strict;
use warnings;
use 5.10.1;

my %exclude = map { $_ => 1 }
  qw(publish subscribe unsubscribe psubscribe punsubscribe );

my %hash;
my (@groups, $group, $command, @args, $text);
my ($in_section, $in_nav, $in_args);

while (my $line = <>) {
    chomp $line;

    $line =~ m|<section id="commands">|
      and $in_section=1, next;
    $in_section && $line =~ m|<nav>|
      and $in_nav=1, next;
    $in_section && $in_nav && $line =~ m|<a href="#([^"]+?)">(.+?)</a>|
      and push(@groups,[$1, $2]), next;
    $in_section && $in_nav && $line =~ m|</nav>|
      and $in_section = 0, $in_nav = 0, next;

    $line =~ m|li data-group="(.+?)".+?">|
      and $group = $1,
          next;
    $line =~ m|href="/commands/(.+?)">.+?</a>|
      and $command=$1, @args=(), next;
    $line =~ m|<span class="args">|
      and $in_args = 1, next;
    $in_args && $line =~ m|</span>|
      and $in_args = 0, next;
    $in_args
      and push(@args, $line =~ s/^\s+|\s+$//rg),
      next;
    ( ($text) = $line =~ m|<span class="summary">(.+?)</span>| )
      && ! $exclude{$command}
      and $hash{$group}{$command =~ s/-/_/gr} = {
              text => $text,
              synopsis => '$r->' . ($command =~ s/-/_/gr). '('
                          . join(', ', @args)
                          . ')',
              ref => $command,
          },
          @args = ();
}

my $pod = '';
foreach (@groups) {
    my ($group, $name) = @$_;
    $pod .= "=head1 " . uc($name) . "\n\n";
    foreach my $command (sort keys %{$hash{$group}}) {
        my %h = %{$hash{$group}{$command}};
        $pod .= "=head2 $command\n\n"
          . "  $h{synopsis}\n\n"
          . $h{text} . " (see L<https://redis.io/commands/$h{ref}>)\n\n";
    }
}
say $pod;
