use v6;

use JSON::Tiny;
use LWP::Simple;

sub clone-repo($repo-url) {
    my $command = "cd ecosystem; git clone $repo-url";
    qqx{$command};
}

sub report-unit-required($module-path) {
    print "Checking $module-path... ";
    my $command = "cd $module-path; git grep '^\\(module\\|class\\|grammar\\).*;\\s*\$'";
    my $output = qqx{$command};
    $output ?? say "Found unitless, blockless module/class/grammar declarator"
            !! say "Looks ok";
}

sub MAIN(Bool :$update = False) {
    my $proto-file = $*SPEC.catfile($*PROGRAM_NAME.IO.dirname, "proto.json");
    if !$proto-file.IO.e or $update {
        say "Fetching proto.json from modules.perl6.org";
        LWP::Simple.getstore("http://modules.perl6.org/proto.json", "proto.json");
    }
    my $proto-json = $proto-file.IO.slurp;

    mkdir "ecosystem" unless "ecosystem".IO.e;

    my %ecosystem := from-json($proto-json);
    my @ecosystem-keys = %ecosystem.keys.sort;
    for @ecosystem-keys -> $key {
        my %module-data := %ecosystem{$key};
        my $repo-url = %module-data{'url'};
        my $module-path = $*SPEC.catfile("ecosystem", $repo-url.split(rx/\//)[*-2]);
        clone-repo($repo-url) unless $module-path.IO.e;
        report-unit-required($module-path);
    }
}

# vim: expandtab shiftwidth=4 ft=perl6
