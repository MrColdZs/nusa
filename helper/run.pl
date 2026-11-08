use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "nusa_media") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::nusa_media", $sym)->();
