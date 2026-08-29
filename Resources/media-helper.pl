#!/usr/bin/perl
# The helper CreativeNotch spawns to read now-playing metadata.
#
# It exists only to be an Apple-signed host process. `mediaremoted` gates
# metadata reads on the CALLING process's code-signing identifier, and
# /usr/bin/perl is signed com.apple.perl. The app itself, signed
# com.gcdz.creativenotch, gets nothing. A dylib loaded here inherits
# perl's exemption — that is the whole mechanism.
use strict;
use warnings;
require DynaLoader;

my $dylib = shift @ARGV
    or die "usage: media-helper.pl /absolute/path/to/dylib\n";

# /usr/bin/perl is a HARDENED program, which rejects relative dylib paths
# outright ("relative path not allowed in hardened program"). Checking here
# turns a confusing dyld error into an obvious one.
die "dylib path must be absolute, got: $dylib\n" unless $dylib =~ m{^/};
die "dylib not found: $dylib\n" unless -e $dylib;

my $lib = DynaLoader::dl_load_file($dylib, 0)
    or die "dl_load_file failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "cn_media_stream")
    or die "symbol 'cn_media_stream' not found in $dylib\n";

DynaLoader::dl_install_xsub("main::cn_media_stream", $sym);

$| = 1;    # unbuffered, so the parent sees each line as it is emitted
cn_media_stream();
