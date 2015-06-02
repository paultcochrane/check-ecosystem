use v6;

use JSON::Tiny;
use LWP::Simple;

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
    say @ecosystem-keys.elems ~ " modules in ecosystem to be checked";
    my @unitless-modules;
    for @ecosystem-keys -> $key {
        my %module-data := %ecosystem{$key};
        my $repo-url = %module-data{'url'};
        my $module-path = $*SPEC.catfile($ecosystem-path, $repo-url.split(rx/\//)[*-2]);
        clone-repo($repo-url, $ecosystem-path) unless $module-path.IO.e;
        update-repo($module-path) if $update;
        if unit-required($module-path) {
            my $repo-path = $repo-url.subst('https://github.com/', '');
            fork-repo($repo-path, $user) if should-be-forked($repo-path, $user, @user-forks);
            my $repo-owner = %module-data{'auth'};
            update-repo-origin($module-path, $repo-url, $repo-owner, $user)
                unless has-user-origin($module-path, $repo-url, $repo-owner, $user);
            create-unit-branch($module-path) unless has-unit-branch($module-path);
            push @unitless-modules, $module-path;
        }
    }
    say "Checkout paths of modules with unitless declarators: ";
    say @unitless-modules.join("\n");

    my $num-unitless-modules = @unitless-modules.elems;
    my $num-ecosystem-modules = @ecosystem-keys.elems;
    say "Modules still to be updated: " ~
        "$num-unitless-modules of $num-ecosystem-modules (" ~
        (@unitless-modules.elems*100/@ecosystem-keys.elems).fmt("%02d") ~ "%)";
}

#| return a list of the forks in the given user's GitHub account
sub user-forks($user) {
    my $base-request = "https://api.github.com/users/$user/repos?per_page=100";
    my @headers = qqx{curl -I $base-request}.split(/\n/);
    my $link-line = @headers.grep(/'Link:'/);
    $link-line.subst-mutate('Link: ', '');
    my @links = $link-line.split(/\,\s*/);
    my $last-link = @links.grep(/'rel="last"'/);
    my $last-page = ($last-link ~~ /\&page\=(\d+)/)[0];

    my @repos;
    for 1..$last-page -> $page-number {
        my $repo-json = LWP::Simple.get($base-request ~ "&page=$page-number");
        my $repo-data = from-json($repo-json);
        push @repos, $repo-data.values;
    }

    my @fork-names;
    for @repos -> $repo {
        my $full-name = $repo{'full_name'};
        my $fork-name = $full-name.split(/\//)[*-1];
        @fork-names.push($fork-name) if $repo{'fork'};
    }
    return @fork-names;
}

#| clone the given repo into the ecosystem path
sub clone-repo($repo-url, $ecosystem-path) {
    my $command = "cd $ecosystem-path; git clone $repo-url";
    qqx{$command};
}

#| update the repo at the given path
sub update-repo($module-path) {
    say "Updating $module-path";
    my $origin-url = origin-url($module-path);
    if $origin-url ~~ / 'https://github.com' / {
        qqx{cd $module-path; git pull};
    }
    else {
        qqx{cd $module-path; git fetch upstream master; git merge upstream/master};
        qqx{cd $module-path; git pull origin pr/add-unit-declarator};
    }
}

#| return the URL of the repo's origin repo
sub origin-url($module-path) {
    qqx{cd $module-path; git config remote.origin.url}.chomp;
}

#| check if the unit declarator is required
sub unit-required($module-path) {
    print "Checking $module-path... ";
    # TODO: only check *.pl, *.p6, *.pm and *.pm6 files
    my $command = "cd $module-path; " ~ 'git grep \'^\(module\|class\|grammar\|role\).*[^{}];\s*$\'';
    my $output = qqx{$command};
    $output ?? say "Found unitless, blockless module/class/grammar declarator"
            !! say "Looks ok";

    return $output !~~ '';
}

#| fork the given repository into the given user's GitHub account
sub fork-repo($repo-path, $user) {
    say "Forking $repo-path";
    my $command = "curl -u '$user' -X POST https://api.github.com/repos/$repo-path" ~ "forks";
    qqx{$command};
}

#| determine if the given repo needs to be forked
sub should-be-forked($repo-path, $user, @user-forks) {
    if $repo-path ~~ /$user/ {
        return False;  # it's the user's repo; no fork needed
    }
    else {
        return $repo-path.split(/\//)[*-2] !~~ @user-forks.any;
    }
}

#| point repo's origin to the user's fork
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

#| determine if the repo already uses the user's fork as origin
sub has-user-origin($module-path, $repo-url, $repo-owner, $user) {
    my $origin-url = origin-url($module-path);
    my $new-url = $repo-url.subst($repo-owner, $user);
    $new-url.subst-mutate('https://github.com/', 'git@github.com:');
    $new-url.subst-mutate(/\/$/, '.git');

    return $origin-url eq $new-url;
}

#| create a branch for the unit declarator pull request
sub create-unit-branch($module-path) {
    my $command = "cd $module-path; git co -b pr/add-unit-declarator";
    qqx{$command};
}

#| determine if the repo has a unit declarator branch
sub has-unit-branch($module-path) {
    my $command = "cd $module-path; git branch --list pr/add-unit-declarator";
    my $output = qqx{$command}.chomp;

    return $output !~~ '';
}

# vim: expandtab shiftwidth=4 ft=perl6
