package Liip::Symfony2::Application;

use strict;
use warnings;

use Cwd;
use File::Slurp;
use File::Basename;
use FindBin;
use lib "$FindBin::Bin/../../";
use Liip::YAML;
use YAML qw(LoadFile Dump);

sub new {
    my $class = shift;
    my ($appname, $app, $basedir, $helper, $destprefix) = @_;

    my $self = $app;

    $self->{helper} = $helper;
    $self->{name} = $appname;
    $self->{basedir} = $basedir;
    $self->{appconfig} = {
        DESCRIPTION => ($self->{description} ? $self->{description} : $self->{name}),
        APPNAME     => $self->{name},
    };

    bless $self, $class;

    $self->{wantsweb} = $self->wants_profile('web');
    $self->{wantsdb} = $self->wants_profile('db');
    $self->{isstatic} = $self->wants_profile('static');

    $self->{destination} = $destprefix;
    $self->{destprefix} = "debian/$self->{destination}";

    $self->{hasdynamicyml} = $self->has_dynamic_yml();

    $self->{dynamicparams} = {};
    $self->{extraconfigdata} = '';
    $self->{extratemplatesdata} = '';
    $self->{extrapostinstdata} = '';

    return $self;
}


sub wants_profile {
    my ($self, $profile) = @_;

    return grep(/^$profile$/, @{$self->{profiles}});
}

sub _dynamic_yml_path {
    my $self = shift;
    return "$self->{basedir}/app/$self->{name}/config/dynamic.yml.dist";
}

sub has_dynamic_yml {
    my $self = shift;
    return -r $self->_dynamic_yml_path();
}

sub make_dynamic_yml {
    my $self = shift;
    return unless $self->has_dynamic_yml();

    local $YAML::UseHeader = 0;
    my $dynamictemplate = LoadFile($self->_dynamic_yml_path());
    $dynamictemplate = Liip::YAML::multi_mergekeys($dynamictemplate);

    my $dynamicstr = '';

    foreach my $key (keys %{$dynamictemplate->{parameters}}) {
        my $value = $dynamictemplate->{parameters}->{$key};
        if (ref $value eq '') {
            my $newkey = $self->_make_safe_debconf_key($key);
            $dynamictemplate->{parameters}->{$key} = $newkey;
            $self->{dynamicparams}->{$key} = $value;
        } else {
            # TODO support nested objects later? (including extra databases)
            if ($key ne 'dynamic.doctrine.dbal.default') {
                warn "Found an unsupported parameter type in dynamic.yml.dist: $key";
                next;
            }
            $dynamictemplate->{parameters}->{$key}->{dbname} = '_DBC_DBNAME_';
            $dynamictemplate->{parameters}->{$key}->{driver} = '_DBC_DBTYPE_';
            $dynamictemplate->{parameters}->{$key}->{user} = '_DBC_DBUSER_';
            $dynamictemplate->{parameters}->{$key}->{password} = '_DBC_DBPASS_';
            $dynamictemplate->{parameters}->{$key}->{host} = '_DBC_DBSERVER_';
        }
    }
    write_file("$self->{destprefix}.dynamic.yml.template", Dump($dynamictemplate));
}

sub _make_safe_debconf_key {
    my ($self, $key) = @_;
    $key =~ s/dynamic\.//;
    $key =~ s/\./_/g;
    $key =~ s/-/_/g;
    return uc '__' . $key . '__';
}

sub make_dynamic_debian_constructs {
    my $self = shift;
    if ($self->{dynamicparams}) {
        foreach my $key (keys %{$self->{dynamicparams}}) {
            my $value = $self->{dynamicparams}->{$key};
            my $newkey = $self->_make_safe_debconf_key($key);
            $key =~ s/dynamic\.//;
            $self->{extraconfigdata} .= $self->{helper}->template_string_string("\ndb_input \$PRIORITY _-_PACKAGENAME_-_/$key || true\ndb_go\n", $self->{appconfig}, $self->{name});
            $self->{extratemplatesdata} .= $self->{helper}->template_string_string("\nTemplate: _-_PACKAGENAME_-_/$key\nType: string\nDefault:\nDescription: dynamic.yml parameter $key (example value: $value)\n", $self->{appconfig}, $self->{name});
            $self->{extrapostinstdata} .= $self->{helper}->template_string_string("\ndb_get _-_PACKAGENAME_-_/$key\necho \"define($newkey,\${RET})dnl\" >> \$TMP_M4_FILE\n", $self->{appconfig}, $self->{name});
        }
    }
}

sub sanity_check {
    my $self = shift;
    my $cwd = getcwd();
    my $file;

    # directory structure sanity check
    $file = "app/$self->{name}";
    unless (-r "$cwd/$file") {
        die("$self->{name} is missing directory in the app dir: $file");
    }

    # frontend sanity check
    if ($self->{frontend}) {
        # TODO maybe the kernel check is overzealous?
        $file = "app/$self->{name}/".ucfirst($self->{name})."Kernel.php";
        unless (-r "$cwd/$file") {
            die("$self->{name} wants a frontend but is missing the kernel in the expected location: $file");
        }

        $file = "web/$self->{name}.php";
        unless (-r "$cwd/$file") {
            die("$self->{name} wants a frontend but is missing the frontend controller in the expected location: $file");
        }
        if (-e "$cwd/web/index.php") {
            die("$self->{name} wants a frontend but the existing index.php will be overwritten by: $file");
        }
    }

    # TODO add sanity check for bundles section in packagemanifest.yml

    # db sanity check
    if ($self->{wantsdb}) {
        unless ($self->{dbconfig}
            && $self->{dbconfig}->{create}
            && $self->{dbconfig}->{dbtypes}
        ) {
            die("$self->{name} wants a database but didn't provide any config dbconfig key, required: create (bool) and dbtypes (string, comma separated)");
        }
        $self->{appconfig}->{DBTYPES} = $self->{dbconfig}->{dbtypes};
        $self->{appconfig}->{DBCPREFIX} = $self->{dbconfig}->{create} eq 'false' ? 'frontend.' : '';
    }
}

sub prebuild {
    my $self = shift;
    if ($self->{prebuild}) {
        if (ref $self->{prebuild} eq 'ARRAY') {
            foreach my $command (@{$self->{prebuild}}) {
                system($command);
            }
        } else {
            system($self->{prebuild});
        }
    }
}

sub make_dirs {
    my $self = shift;
    my $dirsdata = $self->{helper}->template_file_string('dirs', $self->{appconfig}, $self->{name});
    $self->{wantsweb} && ($dirsdata .= $self->{helper}->template_file_string('dirs.web', $self->{appconfig}, $self->{name}));
    write_file("$self->{destprefix}.dirs", $dirsdata);
}

sub make_install {
    my $self = shift;

    my $installfile;

    # Default place to ask the deb to put things on install.
    my $safewwwroot = $self->{helper}->safe_wwwroot($self->{name});

    if ($self->{wantsweb}) {
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.apache.conf.redirect.template",
                "usr/share/packaged-site/$self->{destination}/");
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.apache.conf.http.template",
                "usr/share/packaged-site/$self->{destination}/");
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.apache.conf.httpsonly.template",
                "usr/share/packaged-site/$self->{destination}/");
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.apache.conf.mixed.template",
                "usr/share/packaged-site/$self->{destination}/");
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.apachedir.template",
                "usr/share/packaged-site/$self->{destination}/");
        $installfile .= sprintf("%-30s %s\n",
                "$self->{destprefix}.confmodule",
                "usr/share/packaged-site/$self->{destination}/");
    }

    # each bundle needs to be copied
    if ($self->{bundles}) {
        foreach my $bundle (@{$self->{bundles}}) {
            my ($filename, $directories) = fileparse($bundle);
            $installfile .= sprintf("%-30s %s\n", $bundle, $safewwwroot . "$directories");
        }
    }

    # maybe it wants some other stuff too
    if ($self->{installfiles}) {
        foreach my $file (@{$self->{installfiles}}) {
            my ($filename, $directories) = fileparse($file);
            $installfile .= sprintf("%-30s %s\n", $file, $safewwwroot . "$directories");
        }
    }

    # front end script that is used to serve the application
    if ($self->{frontend}) {
        $installfile .= sprintf("%-30s %s\n", "web/$self->{frontend}", $safewwwroot . 'web/');
    }

    # published assets (hopefully created during pre-build)
    if ($self->{assets}) {
        foreach my $asset (@{$self->{assets}}) {
            $installfile .= sprintf("%-30s %s\n", $asset, $safewwwroot . 'web/');
        }
    }

    # if we are using a dynamic.yml file, put the one that we created earlier into the install list.
    if ($self->{hasdynamicyml}) {
        $installfile .= sprintf("%-30s %s\n",
            "$self->{destprefix}.dynamic.yml.template",
            "usr/share/packaged-site/$self->{destination}/");
    }

    write_file($self->{destprefix} . '.install', $installfile);
}

sub make_cron {
    my $self = shift;
    if ($self->{cron}) {
        my $scheduling;
        my $cron_data;
        foreach my $command (keys %{$self->{cron}}) {
            $scheduling = $self->{cron}->{$command};
            my $wwwroot = $self->{helper}->safe_wwwroot($self->{name}, 1);
            $cron_data.= "$scheduling www-data cd $wwwroot && php app/$self->{name}/console $command >> /var/log/sitelogs/$self->{destination}/cron.log 2>&1\n";
        }
        write_file("$self->{destprefix}.cron.d", $cron_data);
    }
}

sub make_templates {
    my $self = shift;
    my $templatedata = $self->{helper}->template_file_string('templates', $self->{appconfig}, $self->{name});
    $templatedata .= $self->{extratemplatesdata};
    write_file("$self->{destprefix}.templates", $templatedata);
}

sub make_config {
    my $self = shift;
    my $configdata = $self->{helper}->template_file_string('config', $self->{appconfig}, $self->{name});
    $self->{wantsdb} && ($configdata .= $self->{helper}->template_file_string('config.db', $self->{appconfig}, $self->{name}));
    $self->{wantsweb} && ($configdata .= $self->{helper}->template_file_string('config.web', $self->{appconfig}, $self->{name}));

    $configdata .= $self->{extraconfigdata};

    write_file("$self->{destprefix}.config", $configdata);
}

sub make_preinst {
    my $self = shift;
    my $preinst = $self->{helper}->template_file_string('preinst', $self->{appconfig}, $self->{name});
    my $preinstweb = $self->{wantsweb} ?  $self->{helper}->template_file_string('preinst.web', $self->{appconfig}, $self->{name}) : '';
    my $preinstdb = $self->{wantsdb} ?  $self->{helper}->template_file_string('preinst.db', $self->{appconfig}, $self->{name}) : '';

    $preinst =~ s/__PREINST.WEB__/$preinstweb/;
    $preinst =~ s/__PREINST.DB__/$preinstdb/;

    write_file("$self->{destprefix}.preinst", $preinst);
}

sub make_postinst {
    my $self = shift;
    my $postinst = $self->{helper}->template_file_string('postinst', $self->{appconfig}, $self->{name});
    my $postinstconstantsweb = $self->{wantsweb} ?  $self->{helper}->template_file_string('postinst.constants.web', $self->{appconfig}, $self->{name}) : '';
    my $postinstconstantsdb = $self->{wantsdb} ?  $self->{helper}->template_file_string('postinst.constants.db', $self->{appconfig}, $self->{name}) : '';
    my $postinstconfigureweb = $self->{wantsweb} ?  $self->{helper}->template_file_string('postinst.configure.web', $self->{appconfig}, $self->{name}) : '';
    my $postinstconfigureendweb = $self->{wantsweb} ?  $self->{helper}->template_file_string('postinst.configure.end.web', $self->{appconfig}, $self->{name}) : '';
    my $postinstconfiguredb = $self->{wantsdb} ?  $self->{helper}->template_file_string('postinst.configure.db', $self->{appconfig}, $self->{name}) : '';

    my $postinstconfigureenddb = '';

    my $pi = '';
    if ($self->{wantsdb} && $self->{dbconfig}->{postinst}) {
        $pi = $self->{dbconfig}->{postinst};
        warn "Using depcreated dbconfig only postinst. Switch to global postinst!";
    }
    if ($self->{postinst}) {
        $pi = $self->{postinst}
    }
    if ($pi) {
        $postinstconfigureenddb .= 'su -c "{ cd _-_WWWROOT_-_ && ';
        my $errstr = '';
        if (ref $pi eq 'ARRAY') {
            foreach my $command (@{$pi}) {
                $postinstconfigureenddb .= " app/_-_APPNAME_-_/console $command &&";
            }
            $errstr = join(', ', @$pi);
            $postinstconfigureenddb =~ s/&&$/;/;
        } else {
            $postinstconfigureenddb .= " app/_-_APPNAME_-_/console $pi ";
            $errstr = $pi;
        }
        $postinstconfigureenddb .= '} || echo \'Sorry, could not execute your postinst commands:  ' . $errstr . ' \' " www-data ';
        $postinstconfigureenddb = $self->{helper}->template_string_string($postinstconfigureenddb, $self->{appconfig}, $self->{name});
    }

    if ($self->{debianpostinst}) { # special hook for "advanced" (read: hacky) usages
        $postinstconfigureenddb .= "\n" . $self->{helper}->template_string_string($self->{debianpostinst}, $self->{appconfig}, $self->{name});
    }

    my $s2 = $self->{isstatic} ? '' : 'y';
    $postinst =~ s/__POSTINST.CONSTANTS.WEB__/$postinstconstantsweb/;
    $postinst =~ s/__POSTINST.CONSTANTS.DB__/$postinstconstantsdb/;
    $postinst =~ s/__POSTINST.CONFIGURE.WEB__/$postinstconfigureweb/;
    $postinst =~ s/__IS_S2_APP__/$s2/;
    $postinst =~ s/__POSTINST.CONFIGURE.DB__/$postinstconfiguredb/;
    $postinst =~ s/__POSTINST.CONFIGURE.END.WEB__/$postinstconfigureendweb/;
    $postinst =~ s/__POSTINST.CONFIGURE.END.DB__/$postinstconfigureenddb/;
    $postinst =~ s/__POSTINST.CONFIGURE.DYNAMIC__/$self->{extrapostinstdata}/;

    write_file($self->{destprefix} . '.postinst', $postinst);
}

sub make_prerm {
    my $self = shift;
    my $prerm = $self->{helper}->template_file_string('prerm', $self->{appconfig}, $self->{name});
    my $prermdb = $self->{wantsdb} ? $self->{helper}->template_file_string('prerm.db', $self->{appconfig}, $self->{name}) : '' ;
    my $prermweb = $self->{wantsweb} ?  $self->{helper}->template_file_string('prerm.web', $self->{appconfig}, $self->{name}) : '';
    $prerm =~ s/__PRERM.DB__/$prermdb/;
    $prerm =~ s/__PRERM.WEB__/$prermweb/;
    write_file($self->{destprefix} . '.prerm', $prerm);
}
sub make_postrm {
    my $self = shift;
    my $postrm = $self->{helper}->template_file_string('postrm', $self->{appconfig}, $self->{name});
    my $postrmdb = $self->{wantsdb} ? $self->{helper}->template_file_string('postrm.db', $self->{appconfig}, $self->{name}) : '' ;
    my $postrmpurgedb = $self->{wantsdb} ? $self->{helper}->template_file_string('postrm.purge.db', $self->{appconfig}, $self->{name}) : '' ;

    $postrm =~ s/__POSTRM.DB__/$postrmdb/;
    $postrm =~ s/__POSTRM.PURGE.DB__/$postrmpurgedb/;

    write_file($self->{destprefix} . '.postrm', $postrm);
}

sub make_apache_config {
    my $self = shift;
    if ($self->{wantsweb}) {
        $self->{helper}->template_file('confmodule', "$self->{destprefix}.confmodule", $self->{appconfig}, $self->{name});
        $self->{helper}->template_file('logrotate', "$self->{destprefix}.logrotate", $self->{appconfig}, $self->{name});
        $self->{appconfig}->{DOCROOTSUBDIR} = '';
        if ($self->{docrootsubdir}) {
            $self->{appconfig}->{DOCROOTSUBDIR} = $self->{docrootsubdir};
        }
        foreach my $f qw(apache.conf.httpsonly apache.conf.http apache.conf.mixed apache.conf.redirect apachedir) {
            $self->{helper}->template_file($f . '.template', "$self->{destprefix}.$f.template", $self->{appconfig}, $self->{name});
        }
    }
}

sub get_renames {
    my $self = shift;
##### dh_install can't handle renames, so we have to rename all files specifically

    my $renames = '';
    if ($self->{frontend}) {
        ##### special handling of frontend scripts
        $renames .= "\n\tmv \$(CURDIR)/debian/_-_PACKAGENAME_-_-$self->{name}/_-_WWWROOTNS_-_-$self->{name}/web/$self->{frontend} "
        . "\$(CURDIR)/debian/_-_PACKAGENAME_-_-$self->{name}/_-_WWWROOTNS_-_-$self->{name}/web/index.php";
    }
    return $renames;
}
1;
