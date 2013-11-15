use 5.18.1;

use Time::HiRes qw(gettimeofday tv_interval);

my $total_bytes = 5_000_000;
my @lengths = (1, 2, 3, 4, 10, 50, 100, 1_000, 10_000);

foreach my $length (@lengths) {

    my $packet_nb = int($total_bytes / $length);
    my %results;

    my $method = "read";
    if (my $pid = open(my $kid, "|-")) {
        # parent
        my $data = 'x' x $length;
        my $i = $packet_nb;
        my $t0 = [gettimeofday];
        while ($i--) {
            print $kid $data;
        }
        close($kid) or warn "kid exited with $?";
        my $elapsed = tv_interval ($t0); # equivalent code
        say "$method: $packet_nb packets of size $length : $elapsed sec";
        $results{$method}{$length} = $elapsed;
    } else {
        # child
        my $data;
        my $i = 0;
        while ($i < $packet_nb) {
            read STDIN, $data, $length, $i*$length;
            $i++;
        }
        length($data) eq $length * $packet_nb
          or say "wrong length : got " . length($data) . " instead of " . $length * $packet_nb;
        exit;  # don't forget this
    }

    my $method = "sysread";
    if (my $pid = open(my $kid, "|-")) {
        # parent
        my $data = 'x' x $length;
        my $i = $packet_nb;
        my $t0 = [gettimeofday];
        while ($i--) {
            syswrite $kid, $data, $length;
        }
        close($kid) or warn "kid exited with $?";
        my $elapsed = tv_interval ($t0); # equivalent code
        say "$method: $packet_nb packets of size $length : $elapsed sec";
        $results{$method}{$length} = $elapsed;
    } else {
        # child
        my $data;
        my $i = 0;
        while ($i < $packet_nb) {
            sysread STDIN, $data, $length, $i*$length;
            $i++;
        }
        length($data) eq $length * $packet_nb
          or say "wrong length : got " . length($data) . " instead of " . $length * $packet_nb;
        exit;  # don't forget this
    }

}
