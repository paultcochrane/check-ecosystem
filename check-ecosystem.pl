use v6;

use JSON::Tiny;
use IO::Socket::SSL;   # implicit dependency for LWP::Simple for ssl
use LWP::Simple;
use File::Find;

# TODO: rewrite to use HTTP::UserAgent instead of curl and LWP::Simple
#
# the reason being, the connection gets throttled if one doesn't make
# authenticated requests, which means after so many unauthenticated
# requests, the code will simply fail without any good cause (because it
# wasn't written well enough to handle this from the beginning).  By making
# authenticated requests, one can run --update several times and the results
# should be repeatable, which isn't necessarily the case without
# authentication.

sub MAIN(
    Str  :$github-user,
         :$module-name = Nil,
    Bool :$update = False,
    Bool :$debug = False
) {
    my $projects-file = $*SPEC.catfile($*PROGRAM-NAME.IO.dirname, "projects.json");
    if !$projects-file.IO.e or $update {
        say "Fetching projects.json from modules.perl6.org";
        LWP::Simple.getstore("http://ecosystem-api.p6c.org/projects.json", "projects.json");
    }
    my $projects-json = $projects-file.IO.slurp;

    my $ecosystem-path = "/tmp/ecosystem";
    mkdir $ecosystem-path unless $ecosystem-path.IO.e;

    my @user-forks = user-forks($github-user, $update);

    my @ecosystem-modules := from-json($projects-json);

    if $module-name {
        @ecosystem-modules = gather
        for @ecosystem-modules -> $module {
            take $module if $module<name> eq $module-name;
        }
    }

    say @ecosystem-modules.elems ~ " modules in ecosystem to be checked";
    my @unitless-modules;
    my @modules-needing-kebab-case-test-funs;
    for @ecosystem-modules -> $module {
        my %module-data := $module;
        my $repo-url = %module-data{'source-url'} // %module-data{'repo-url'} // %module-data{'support'}{'source'};
        my $name = %module-data{"name"};
        my $repo-dir-name = $repo-url.split(rx/\//)[*-1];
        $repo-dir-name ~~ s/\.git//;
        unless $repo-dir-name {
            say "Module '$name has an invalid GitHub url: '$repo-url'";
            next;
        }
        my $module-path = $*SPEC.catfile($ecosystem-path, $repo-dir-name);
        clone-repo($repo-url, $ecosystem-path) unless $module-path.IO.e;
        update-repo($module-path) if $update;
        if unit-required($module-path) {
            my $repo-path = $repo-url.subst(/ [https||git] '://github.com/' /, '');
            $repo-path ~~ s/\.git$//;
            fork-repo($repo-path, $github-user) if should-be-forked($repo-path, $github-user, @user-forks);
            update-repo-origin($module-path, $repo-url, $github-user)
                unless has-user-origin($module-path, $repo-url, $github-user);
            create-unit-branch($module-path) unless has-unit-branch($module-path);
            push @unitless-modules, $module-path;
        }
        if kebab-case-test-functions($module-path) {
            my $repo-path = $repo-url.subst(/ [https||git] '://github.com/' /, '');
            $repo-path ~~ s/\.git$//;
            fork-repo($repo-path, $github-user) if should-be-forked($repo-path, $github-user, @user-forks);
            update-repo-origin($module-path, $repo-url, $github-user)
                unless has-user-origin($module-path, $repo-url, $github-user);
            create-kebab-case-branch($module-path) unless has-kebab-case-branch($module-path);
            my $branch-name = "pr/use-kebab-case-test-funs";
            if remote-branch-exists($repo-url, $github-user, $branch-name) {
                say "Remote branch exists: $repo-url" if $debug;

                # check out the branch
                qqx{cd $module-path; git checkout $branch-name};
                # pull
                qqx{cd $module-path; git branch --set-upstream-to=origin pr/use-kebab-case-test-funs};
                qqx{cd $module-path; git pull origin pr/use-kebab-case-test-funs};
            }
            # run the check again
            my $kebab-case-needed = kebab-case-test-functions($module-path);

            # now getting *very* obvious that this code needs to be
            # rewritten.  It needs to be object oriented and needs tests.
            # Also how a given module is checked is slowly turning into
            # spaghetti, hence this is *not* the final way to do this.
            # Let's, however, get it running so that the kebab-case checks
            # work

            $module<checkout-path> = $module-path;
            if $kebab-case-needed {
                push @modules-needing-kebab-case-test-funs, $module;
            }
        }
    }

    # report if broken on master, but fixed on branch
    #
    # need to set branch name in metadata somehow -> this would then be
    # easier to carry around such information

    # set upstream tracking information and pull

    say "Checkout paths of modules with unitless declarators: ";
    say @unitless-modules.join("\n");

    my $num-unitless-modules = @unitless-modules.elems;
    my $num-ecosystem-modules = @ecosystem-modules.elems;
    say "Modules still to be updated: " ~
        "$num-unitless-modules of $num-ecosystem-modules (" ~
        ($num-unitless-modules*100/$num-ecosystem-modules).fmt("%02d") ~ "%)";

    say "Checkout paths of modules requiring kebab-case test functions: ";
    say (@modules-needing-kebab-case-test-funs>><checkout-path> Z @modules-needing-kebab-case-test-funs>><name>).join("\n") if @modules-needing-kebab-case-test-funs;

    my $num-kebab-case-modules = @modules-needing-kebab-case-test-funs.elems;
    $num-ecosystem-modules = @ecosystem-modules.elems;
    say "Modules still to be updated: " ~
        "$num-kebab-case-modules of $num-ecosystem-modules (" ~
        ($num-kebab-case-modules*100/$num-ecosystem-modules).fmt("%02d") ~ "%)";
}

#| return a list of the forks in the given user's GitHub account
sub user-forks($github-user, $is-update) {
    my @fork-names;
    my $forks-file = "user-forks.dat";
    if $is-update {
        my $base-request = "https://api.github.com/users/$github-user/repos?per_page=100";
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

        for @repos -> $repo {
            my $full-name = $repo{'full_name'};
            my $fork-name = $full-name.split(/\//)[*-1];
            @fork-names.push($fork-name) if $repo{'fork'};
        }
        spurt $forks-file, @fork-names.perl;
    }
    else {
        @fork-names = EVAL $forks-file.IO.slurp;
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
    if $origin-url ~~ / 'git://github.com' || 'https://github.com' / {
        qqx{cd $module-path; git checkout master; git pull};
    }
    else {
        qqx{cd $module-path; git checkout master; git fetch upstream master; git merge upstream/master};
    }
}

#| return the URL of the repo's origin repo
sub origin-url($module-path) {
    qqx{cd $module-path; git config remote.origin.url}.chomp;
}

#| check if the unit declarator is required
sub unit-required($module-path) {
    print "Checking $module-path... ";
    my @files := find(:dir($module-path), :type("file"),
                        :name(/ \.pl$ || \.p6$ || \.t$ || \.pm$ || \.pm6$ /)).list;
    my @unitless-files;
    for @files -> $file {
        my @lines = $file.IO.lines;
        push @unitless-files, $file
            if @lines.grep(/ ^(module||class||grammar||role).* <-[{}]> \; \s*$ /);
    }

    if @unitless-files {
        say "Found unitless, blockless module/class/grammar/role declarator";
        say "Affected files:";
        say @unitless-files.join("\n");
    }
    else {
        say "Looks ok";
    }

    return @unitless-files.Bool;
}

#| check if the kebab-case test functions are required
sub kebab-case-test-functions($module-path) {
    print "Checking $module-path... ";
    my @files := find(:dir($module-path), :type("file"),
                        :name(/ \.pl$ || \.p6$ || \.t$ || \.pm$ || \.pm6$ /)).list;
    my @kebab-case-needing-files;
    for @files -> $file {
        my @lines = $file.IO.lines.grep(/ ^^ <-[#]> /);
        push @kebab-case-needing-files, $file
            if @lines.grep(/ ( dies_ok || lives_ok || use_ok || cmd_ok || is_deeply || skip_rest || is_approx || isa_ok || eval_dies_ok || eval_lives_ok || throws_like ).* <-[{}]> \; \s*$ /);
    }

    if @kebab-case-needing-files {
        say "Found files requiring kebab-case test functions";
        say "Affected files:";
        say @kebab-case-needing-files.join("\n");
    }
    else {
        say "Looks ok";
    }

    return @kebab-case-needing-files.Bool;
}

#| fork the given repository into the given user's GitHub account
sub fork-repo($repo-path, $github-user) {
    say "Forking $repo-path";
    my $command = "curl -u '$github-user' -X POST https://api.github.com/repos/$repo-path/" ~ "forks";
    my $status = shell $command;
    die "Fork command failed: $command" if $status.exitcode != 0;
}

#| determine if the given repo needs to be forked
sub should-be-forked($repo-path, $github-user, @user-forks) {
    if $repo-path ~~ /$github-user/ {
        return False;  # it's the user's repo; no fork needed
    }
    else {
        my $repo-name = $repo-path.split(/\//)[*-1];
        $repo-name ~~ s/\.git$//;
        return $repo-name !~~ @user-forks.any;
    }
}

#| point repo's origin to the user's fork
sub update-repo-origin($module-path, $repo-url, $github-user) {
    say "Pointing repo's origin to $github-user\'s fork";
    my $new-url = $repo-url.subst(/ [https || git] '://github.com/' /, 'git@github.com:');
    $new-url ~~ m/ \: ( .* ) \/ /;
    my $repo-owner = $0;
    $new-url ~~ s/$repo-owner/$github-user/;
    my $command = "cd $module-path; git remote set-url origin $new-url";
    qqx{$command};

    my $upstream-url = $repo-url.subst('git://github.com/', 'git@github.com:');
    $command = "cd $module-path; git remote add upstream $upstream-url";
    qqx{$command};
}

#| determine if the repo already uses the user's fork as origin
sub has-user-origin($module-path, $repo-url, $github-user) {
    my $origin-url = origin-url($module-path);
    my $new-url = $repo-url.subst(/ [https || git] '://github.com/' /, 'git@github.com:');
    $new-url ~~ m/ \: ( .* ) \/ /;
    my $repo-owner = $0;
    $new-url ~~ s/$repo-owner/$github-user/;

    return $origin-url eq $new-url;
}

#| create a branch for the unit declarator pull request
sub create-unit-branch($module-path) {
    my $command = "cd $module-path; git checkout master; git checkout -b pr/add-unit-declarator";
    qqx{$command};
}

#| determine if the repo has a unit declarator branch
sub has-unit-branch($module-path) {
    my $command = "cd $module-path; git branch --list pr/add-unit-declarator";
    my $output = qqx{$command}.chomp;

    return $output !~~ '';
}

#| create a branch for the kebab-case test functions pull request
sub create-kebab-case-branch($module-path) {
    my $command = "cd $module-path; git checkout master; git checkout -b pr/use-kebab-case-test-funs";
    qqx{$command};
}

#| determine if the repo has a kebab-case test functions branch
sub has-kebab-case-branch($module-path) {
    my $command = "cd $module-path; git branch --list pr/use-kebab-case-test-funs";
    my $output = qqx{$command}.chomp;

    return $output !~~ '';
}

#| determine if the remote branch exists
sub remote-branch-exists($repo-url, $github-user, $branch-name) {
    my $repo-name = repo-name-from-url($repo-url);
    my $base-request = "https://api.github.com/repos/$github-user/";
    my $branch-url = $base-request ~ "$repo-name/branches/$branch-name";
    my $branch-json = LWP::Simple.get($branch-url);
    if $branch-json {
        my $branch-info = from-json($branch-json);
        return $branch-info<name>:exists;
    }
    else {
        return False;
    }
}

#| determine and return the repo's name from the repo's url
sub repo-name-from-url($repo-url) {
    my $repo-name = $repo-url.split(/\//)[*-1];
    $repo-name ~~ s/\.git$//;

    return $repo-name;
}

# vim: expandtab shiftwidth=4 ft=perl6
