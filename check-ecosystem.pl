use v6;

use JSON::Tiny;
use LWP::Simple;

sub user-forks($user) {
    my $repo-json = LWP::Simple.get("https://api.github.com/users/$user/repos?per_page=1000");
    my $repo-data = from-json($repo-json);
    my @repos = $repo-data.values;
    my @fork-names;
    for @repos -> $repo {
        my $full-name = $repo{'full_name'};
        my $fork-name = $full-name.split(/\//)[*-1];
        @fork-names.push($fork-name) if $repo{'fork'};
    }
    return @fork-names;
}

sub clone-repo($repo-url, $ecosystem-path) {
    my $command = "cd $ecosystem-path; git clone $repo-url";
    qqx{$command};
}

sub update-repo($module-path) {
    say "Updating $module-path";
    my $origin-url = origin-url($module-path);
    if $origin-url ~~ / 'https://github.com' / {
        qqx{cd $module-path; git pull};
    }
    else {
        qqx{cd $module-path; git fetch upstream master; git merge upstream/master};
    }
}

sub origin-url($module-path) {
    qqx{cd $module-path; git config remote.origin.url}.chomp;
}

sub report-unit-required($module-path) {
    print "Checking $module-path... ";
    my $command = "cd $module-path; " ~ 'git grep \'^\(module\|class\|grammar\).*[^{}];\s*$\'';
    my $output = qqx{$command};
    $output ?? say "Found unitless, blockless module/class/grammar declarator"
            !! say "Looks ok";

    return $output !~~ '';
}

sub fork-repo($repo-path, $user) {
    say "Forking $repo-path";
    my $command = "curl -u '$user' -X POST https://api.github.com/repos/$repo-path" ~ "forks";
    qqx{$command};
}

sub has-been-forked($repo-path, @user-forks) {
    return $repo-path.split(/\//)[*-2] ~~ @user-forks.any
}

sub update-repo-origin($module-path, $repo-url, $repo-owner, $user) {
    say "Pointing repo's origin to $user\'s fork";
    my $new-url = $repo-url.subst($repo-owner, $user);
    $new-url.subst-mutate('https://github.com/', 'git@github.com:');
    $new-url.subst-mutate(/\/$/, '.git');
    my $command = "cd $module-path; git remote set-url origin $new-url";
    qqx{$command};
    my $upstream-url = $repo-url.subst('https://github.com/', 'git@github.com:');
    $upstream-url.subst-mutate(/\/$/, '.git');
    $command = "cd $module-path; git remote add upstream $upstream-url";
    qqx{$command};
}

sub has-user-origin($module-path, $repo-url, $repo-owner, $user) {
    my $origin-url = origin-url($module-path);
    my $new-url = $repo-url.subst($repo-owner, $user);
    $new-url.subst-mutate('https://github.com/', 'git@github.com:');
    $new-url.subst-mutate(/\/$/, '.git');

    return $origin-url eq $new-url;
}

sub create-unit-branch($module-path) {
    my $command = "cd $module-path; git co -b pr/add-unit-declarator";
    qqx{$command};
}

sub has-unit-branch($module-path) {
    my $command = "cd $module-path; git branch --list pr/add-unit-declarator";
    my $output = qqx{$command}.chomp;

    return $output !~~ '';
}

sub MAIN($user, Bool :$update = False) {
    my $proto-file = $*SPEC.catfile($*PROGRAM_NAME.IO.dirname, "proto.json");
    if !$proto-file.IO.e or $update {
        say "Fetching proto.json from modules.perl6.org";
        LWP::Simple.getstore("http://modules.perl6.org/proto.json", "proto.json");
    }
    my $proto-json = $proto-file.IO.slurp;

    my $ecosystem-path = "/tmp/ecosystem";
    mkdir $ecosystem-path unless $ecosystem-path.IO.e;

    my @user-forks = user-forks($user);

    my %ecosystem := from-json($proto-json);
    my @ecosystem-keys = %ecosystem.keys.sort;
    for @ecosystem-keys -> $key {
    say @ecosystem-keys.elems ~ " modules in ecosystem to be checked";
        my %module-data := %ecosystem{$key};
        my $repo-url = %module-data{'url'};
        my $module-path = $*SPEC.catfile($ecosystem-path, $repo-url.split(rx/\//)[*-2]);
        clone-repo($repo-url, $ecosystem-path) unless $module-path.IO.e;
        update-repo($module-path) if $update;
        my $unit-is-required = report-unit-required($module-path);
        if $unit-is-required {
            my $repo-path = $repo-url.subst('https://github.com/', '');
            fork-repo($repo-path, $user) unless has-been-forked($repo-path, @user-forks);
            my $repo-owner = %module-data{'auth'};
            update-repo-origin($module-path, $repo-url, $repo-owner, $user)
                unless has-user-origin($module-path, $repo-url, $repo-owner, $user);
            create-unit-branch($module-path) unless has-unit-branch($module-path);
        }
    }
}

# vim: expandtab shiftwidth=4 ft=perl6
