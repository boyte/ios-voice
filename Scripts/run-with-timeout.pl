#!/usr/bin/env perl
use strict;
use warnings;

# Usage: run-with-timeout.pl SECONDS LABEL COMMAND [ARG...]
#
# macOS does not ship GNU timeout. Unlike an alarm followed by exec, this
# launcher remains the parent of the command, owns a separate child process
# group, and can terminate the entire command tree when the deadline expires.
my ($seconds, $label, @command) = @ARGV;
die "usage: run-with-timeout.pl SECONDS LABEL COMMAND [ARG...]\n"
    unless defined $seconds && $seconds =~ /\A[1-9][0-9]*\z/
        && defined $label && @command;

my $pid = fork();
die "unable to fork timeout child: $!\n" unless defined $pid;

if ($pid == 0) {
    setpgrp(0, 0) or die "unable to create timeout process group: $!\n";
    exec @command;
    die "unable to execute $command[0]: $!\n";
}

my $timed_out = 0;
$SIG{ALRM} = sub {
    $timed_out = 1;
    print STDERR "$label watchdog expired after $seconds seconds\n";
    kill 'TERM', -$pid;
    select undef, undef, undef, 2;
    kill 'KILL', -$pid;
};
alarm $seconds;
waitpid($pid, 0);
alarm 0;

exit 124 if $timed_out;
my $status = $?;
exit 128 + ($status & 127) if $status & 127;
exit $status >> 8;
