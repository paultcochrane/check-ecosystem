use v6;

use JSON::Tiny;

sub checkout-repo($repo-url) {
    my $command = "git clone $repo-url";
    qqx{$command};
}

sub report-unit-required($module-path) {
    print "Checking $module-path... ";
    my $command = "cd $module-path; git grep '^\\(module\\|class\\|grammar\\).*;\\s*\$'";
    my $output = qqx{$command};
    $output ?? say "Found unitless, blockless module/class/grammar declarator"
            !! say "Looks ok";
}

sub MAIN {
    my $proto-file = $*SPEC.catfile($*PROGRAM_NAME.IO.dirname, "proto.json");
    my $proto-json = $proto-file.IO.slurp;

    my %ecosystem := from-json($proto-json);
    my @ecosystem-keys = %ecosystem.keys.sort;
    for @ecosystem-keys -> $key {
        my %module-data := %ecosystem{$key};
        my $repo-url = %module-data{'url'};
        my $module-path = $repo-url.split(rx/\//)[*-2];
        checkout-repo($repo-url) unless $module-path.IO.e;
        report-unit-required($module-path);
    }
}

# vim: expandtab shiftwidth=4 ft=perl6
