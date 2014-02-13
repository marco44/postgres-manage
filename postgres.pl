#!/usr/bin/perl -w
use Getopt::Long;
use File::Basename;
use Data::Dumper;


use strict;

# Ces 3 sont en our pour pouvoir les manipuler par référence symbolique (paresse quand tu nous tiens)
# Ça évite de stocker dans un hash, ou de devoir faire une floppée de if dans la fonction
# de chargement de la conf
our $parallelisme;
our $work_dir;
our $git_local_repo;
our $doxy_file;
our $CC;
our $CFLAGS;
our $CONFIGOPTS; # Ne pas confondre avec $configopt (la ligne de commande qui va être réellement passée à configure)

my $conf_file;

my $version;
my $mode;
my $configopt;


my %postgis_version=(  '9.2' => {  'geos'   => 'geos-3.3.9',
	                           'proj'   =>'proj-4.8.0',
		                   'jsonc'  =>'json-c-0.9',
			           'gdal'   =>'gdal-1.9.2',
				   'postgis'=>'postgis-2.0.4',
				},
			'9.3' => { 'geos'   => 'geos-3.4.2',
	                           'proj'   =>'proj-4.8.0',
		                   'jsonc'  =>'json-c-0.9',
			           'gdal'   =>'gdal-1.9.2',
				   'postgis'=>'postgis-2.1.0',
				},
			'8.2' => { 'geos'   => 'geos-3.3.9',
	                           'proj'   =>'proj-4.5.0',
			           'gdal'   =>'gdal-1.9.2',
				   'postgis'=>'postgis-1.3.2',
				},
		    );



sub majeur_mineur
{
	my ($version)=@_;
	$version=~ /^(\d+)\.(\d+)(?:\.(.+))?$/ or die "Version bizarre $version dans majeur_mineur\n";
	return ($1,$2,$3);
}

sub calcule_mineur
{
	my ($mineur)=@_;
	my $score;
	if ($mineur =~ /^(alpha|beta|rc)(\d+)$/)
	{
		if ($1 eq 'alpha')
		{
			$score=0+$2;
		}
		elsif ($1 eq 'beta')
		{
			$score=100+$2;
		}
		elsif ($1 eq 'rc')
		{
			$score=200+$2;
		}
	}
	elsif ($mineur =~ /^(\d+)$/)
	{
		$score=300+$1;
	}
	else
	{
		die "Mineur non prévu\n";
	}
	return $score;
}

# Retourne comme cmp et <=> par rapport à 2 versions en paramètre
# Accepte les formats 9.3, 9.3.9, 9.3.beta1
sub compare_versions
{
	my ($version1,$version2)=@_;
	# Cas de sortie:
	return -1 if ($version1 eq 'dev');
	return 1 if ($version2 eq 'dev');
	# 9.3 et 9.3.0 c'est pareil. On commence par ça
	if ($version1 =~ /^\d+\.\d+$/)
	{
		$version1=$version1 . ".0";
	}
	if ($version2 =~ /^\d+\.\d+$/)
	{
		$version2=$version2 . ".0";
	}
	# On commence par comparer les majeurs. Ça suffit la plupart du temps
	my ($majeur11,$majeur21,$mineur1)=majeur_mineur($version1);
	my ($majeur12,$majeur22,$mineur2)=majeur_mineur($version2);
	if ($majeur11<=>$majeur12)
	{
		return $majeur11<=>$majeur12;
	}
	if ($majeur21<=>$majeur22)
	{
		return $majeur21<=>$majeur22;
	}
	# Fin du cas simple :)
	# Maintenant, si les mineurs sont juste des numériques, c'est facile. Sinon, il faut prendre en compte que
	# rc>beta>alpha. Pour rendre la comparaison simple, alpha=0, beta=100, rc=200, final=300.
	# On les somme au numéro de version trouvé. C'est ce que fait la fonction calcule_mineur
	my $score1=calcule_mineur($mineur1);
	my $score2=calcule_mineur($mineur2);
	return $score1<=>$score2;
}

# Cette fonction rajoute des options de config pour les cas spéciaux (vieilles versions avec pbs d'options de compil, etc
# Cette fonction utilise la fonction de comparaisons de versions pour faire ses petites affaires.
# On y change les configopt au besoin, l'environnement (CC, CFLAGS…)
# Pour le moment elle est vide :)
sub special_case_compile
{
	my ($version)=@_;
	return $configopt;
}

# Convertir une version en tag git
sub version_to_REL
{
	my ($version)=@_;
	if  ($version =~ /^dev|^review/)
	{
		return 'master';
	}
	my $rel=$version;
	$rel=~ s/\./_/g;
	$rel=~ s/beta/BETA/g;
	$rel=~ s/alpha/ALPHA/g;
	$rel=~ s/rc/RC/g;
	$rel="REL" . $rel;
	return $rel;
}

# Pour éviter d'avoir des die partout dans le code
sub system_or_die
{
	my ($command)=@_;
	my $rv=system($command);
	if ($rv>>8 != 0)
	{
		die "Commande $command a echoué.\n";
	}

}

sub dest_dir
{
	my ($version)=@_;
	return("${work_dir}/postgresql-${version}");
}

sub build
{
	my ($tobuild)=@_;
	my $dest=dest_dir($tobuild);
	# Options de compil par défaut
	if (not defined $CC)
	{
		undef $ENV{CC};
	}
	else
	{
		$ENV{CC}=$CC;
	}
	if (not defined $CFLAGS)
	{
		undef $ENV{CFLAGS};
	}
	else
	{
		$ENV{CFLAGS}=$CFLAGS;
	}
	# construction du configure
	$configopt="--prefix=$dest $CONFIGOPTS";
	my $tag=version_to_REL($tobuild);
	clean($tobuild);
	mkdir ("${dest}") or die "Cannot mkdir ${dest} : $!\n";
	chdir "${dest}" or die "Cannot chdir ${dest} : $!\n";
	system_or_die("git clone ${git_local_repo} src");
	chdir "src" or die "Cannot chdir src : $!\n";
	system_or_die("git reset --hard");
	system_or_die("git checkout $tag"); # à tester pour le head
	system_or_die("rm -rf .git"); # On se moque des infos git maintenant
#	system_or_die ("cp -rf ${git_local_repo}/../xlogdump ${dest}/src/contrib/");
	special_case_compile($tobuild);
	system_or_die("./configure $configopt");
	system_or_die("nice -19 make -j${parallelisme} && make check && make install && cd contrib && make -j3 && make install");
}

# Fonction générique de compilation.
sub build_something
{
	my ($dir,$tar,@commands)=@_;
	system_or_die("tar xvf $tar");
	chdir ($dir);
	foreach my $command(@commands)
	{
		system_or_die($command);
	}
	chdir ('..');
	system_or_die("rm -rf $dir");
}

# Génération d'un doxygen. À partir d'un fichier Doxyfile qui doit être indiqué dans la conf.
sub doxy
{
	my ($version)=@_;
	my $dest=dest_dir($version);
	# Creation du fichier doxygen
	my $src_doxy="${dest}/src/";
	my $dest_doxy="${dest}/doxygen/";
	mkdir("${dest_doxy}");
	open DOXY_IN,$doxy_file or die "Impossible de trouver le fichier de conf doxygen $doxy_file: $!";
	open DOXY_OUT,"> ${dest_doxy}/Doxyfile" or die "Impossible de créer ${dest_doxy}/Doxyfile: $!";
	while (my $line=<DOXY_IN>)
	{
		$line =~ s/\$\$OUT_DIRECTORY\$\$/${dest_doxy}/;
		$line =~ s/\$\$IN_DIRECTORY\$\$/${src_doxy}/;
		$line =~ s/\$\$VERSION\$\$/$version/;
		print DOXY_OUT $line;
	}
	close DOXY_OUT;
	close DOXY_IN;
	# On peut générer le doxygen
	system("doxygen ${dest_doxy}/Doxyfile");
	# Maintenant, vu la quantité de fichiers html dans le résultat, on crée une page index.html
	# à la racine du rep doxy, qui redirige
	open DOXY_OUT,"> ${dest_doxy}/index.html" or die "impossible de créer ${dest_doxy}/index.html: $!";
	print DOXY_OUT << 'THEEND';
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="refresh" content="0; url=html/index.html" />
</head>
<body>
</body>
</html>

THEEND
	close DOXY_OUT;
}

# Pour celle la, il faut avoir les tar.gz de toutes les libs en dessous, dans la bonne version. C'est
# basique pour le moment, mais on fait peu de postgis, donc pas eu envie de m'emmerder :)
sub build_postgis
{
	my ($tobuild)=@_;
	# Test que le LD_LIBRARY_PATH est bon avant d'aller plus loin
	unless (defined $ENV{LD_LIBRARY_PATH} and $ENV{LD_LIBRARY_PATH} =~ /proj/)
	{
		die "Il faut que le LD_LIBRARY_PATH soit positionné. Lancez ce script en mode env, et importez les variables\n";
	}
	my ($majeur1,$majeur2)=majeur_mineur($tobuild);
	my $majeur=$majeur1 . '.' . $majeur2;
	unless (defined $postgis_version{$majeur})
	{
		die "Impossible de déterminer les versions de postgis à utiliser pour la version postgres $majeur";
	}
	no warnings; # Il va y avoir de l'undef ci-dessous
	my $refversion=$postgis_version{$majeur};
	my $geos=$refversion->{'geos'};
	my $proj=$refversion->{'proj'};
	my $jsonc=$refversion->{'jsonc'};
	my $gdal=$refversion->{'gdal'};
	my $postgis=$refversion->{'postgis'};
	system("rm -rf $geos $proj $postgis $jsonc $gdal");

	use warnings;

	my $dest=dest_dir($tobuild);
	chdir("$work_dir/postgis") or die "Ne peux pas entrer dans $work_dir/postgis:$!\n";

	my $postgis_options='';
	# On va modifier le PATH au fur et à mesure de la compil: les vieilles versions de postgis ne prenaient pas les chemins dans le configure
	if (defined $geos)
	{
		build_something($geos,"${geos}.tar.bz2","./configure --prefix=${dest}/geos","make -j $parallelisme","make install");
		$postgis_options.=" --with-geosconfig=${dest}/geos/bin/geos-config";
		$ENV{PATH}="${dest}/geos/bin/" . ':' . $ENV{PATH};
	}
	if (defined $proj)
	{
		build_something($proj,"${proj}.tar.gz","./configure --prefix=${dest}/proj","make -j $parallelisme","make install");
		$postgis_options.=" --with-projdir=${dest}/proj";
		$ENV{PATH}="${dest}/proj/bin/" . ':' . $ENV{PATH};
	}
	if (defined $jsonc)
	{
		build_something($jsonc,"${jsonc}.tar.gz","./configure --prefix=${dest}/jsonc","make","make install");
		$postgis_options.=" --with-jsondir=${dest}/jsonc";
	}
	if (defined $gdal)
	{
		build_something($gdal,"${gdal}.tar.gz","./configure --prefix=${dest}/gdal","make -j $parallelisme","make install");
		$postgis_options.=" --with-gdalconfig=${dest}/gdal/bin/gdal-config";
	}
	build_something($postgis,"${postgis}.tar.gz","./configure $postgis_options --prefix=${dest}/postgis","make -j $parallelisme","make","make install");
	print "Compilation postgis OK\n";

}

sub list
{
	my @list=<$work_dir/postgresql-*/>;
	my @retour;
	foreach my $elt (sort @list)
	{
		my $basename_rep_git=basename($git_local_repo); # Il va souvent être dans le même répertoire. Il faut l'ignorer
		next if ($elt =~ /$basename_rep_git/);
		$elt=~/postgresql-(.*)\/$/;
		push @retour,($1);
	}
	return (\@retour);
}
sub list_avail
{
	chdir ("$git_local_repo") or die "Il n'y a pas de répertoire $git_local_repo\nClones en un à coup de git clone git://git.postgresql.org/git/postgresql.git";
	my @versions=`git tag`;
	my @retour;
	foreach my $version(@versions)
	{
		chomp $version;
		next unless ($version =~ /^REL/);
		next if ($version =~ /RC|BETA|ALPHA/);
		$version =~ s/^REL//g;
		$version =~ s/_/./g;
		push @retour, ($version)
	}
	return(\@retour);
}

sub ls_latest
{
	my $refversions=list_avail();
	my $prevversion='';
	my $prevmajeur='';
	my @retour;
	foreach my $version(sort {compare_versions($a,$b) } @$refversions)
	{
		$version=~/^(\d+\.\d+)/;
		my $majeur=$1;
		if ($prevmajeur and ($majeur ne $prevmajeur))
		{
			push @retour, ($prevversion);
		}
		$prevmajeur=$majeur;
		$prevversion=$version;
	}
	push @retour, ($prevversion);
	return(\@retour);
}

sub rebuild_latest
{
	my @latest=@{ls_latest()};
	foreach my $version(@latest)
	{
		my $deja_compile=0;
		my ($majeur1,$majeur2)=majeur_mineur($version);
		my @olddirs=<$work_dir/postgresql-${majeur1}.${majeur2}*>;
		# Le nom des olddirs va ressembler à /home/marc/postgres/postgresql-9.3.0
		foreach my $olddir(@olddirs)
		{
			$olddir=~ /(\d+\.\d+\.\d+)$/ or die "Nom de dir bizarre: $olddir\n";
			my $oldversion=$1;
			if (compare_versions($oldversion,$version)==0)
			{
				print "La version $version est deja compilee.\n";
				$deja_compile=1;
			}
			else
			{
				print "Suppression de la version obsolete $oldversion.\n";
				system_or_die ("rm -rf $olddir");
			}
		}
		# Seulement les versions >= 8.4 (versions supportées)
		unless ($deja_compile or compare_versions($version,'8.4.0')==-1)
		{
			print "Compilation de $version.\n";
			build($version);
		}
	}
}

sub clean
{
	my ($version)=@_;
	my $dest=dest_dir($version);
	stop($version,'immediate'); # Si ça ne réussit pas, tant pis
	system_or_die("rm -rf $dest");
}
#
# Cette fonction ne fait qu'afficher le shell à exécuter
# On ne peut évidemment pas modifier l'environnement du shell appelant directement en perl
# Elle doit être appelée par le shell avec un ` `
sub env
{
	unless ($version)
	{
		print STDERR "Hé, j'ai besoin d'un numero de version\n";
		die;
	}
	# On nettoie le path des anciennes versions, au cas où
	my $oldpath=$ENV{PATH};
	$oldpath =~ s/${work_dir}.*?\/bin://g;
	my $dir=dest_dir($version);
	print "export PATH=${dir}/bin:" . $oldpath . "\n";
	print "export PAGER=less\n";
	print "export PGDATA=${dir}/data\n";
	print "export LD_LIBRARY_PATH=${dir}/proj/lib:${dir}/geos/lib:${dir}/jsonc/lib:${dir}/gdal/lib:${dir}/lib\n";
	print "export pgversion=$version\n";
	if ($version =~ /^(\d+)\.(\d+)\.(?:(\d+)|(alpha|beta|rc)(\d+))?$/)
	{
		my $minor='';
		if (defined $4)
		{
			my $prefix;
			if ($4 eq 'alpha')
			{
				$prefix='0';
			}
			elsif ($4 eq 'beta')
			{
				$prefix='1';
			}
			else
			{
				$prefix='2';
			}
			# On part de l'hypothèse qu'il n'y a pas plus de 9 betas/alphas/rc
			$minor=$prefix.$5;
		}
		else
		{
			$minor=$3;
		}
		# Version numérique
		print "export PGPORT=5".$1.$2.$minor."\n";
	}
	elsif ($version eq 'review')
	{
		print "export PGPORT=6666\n";
	}
	elsif ($version eq 'dev')
	{
		print "export PGPORT=6667\n";
	}
	else
	{
		die "Version incompréhensible: <$version>\n";
	}
}

sub start
{
	my ($version)=@_;
	my $dir=dest_dir($version);
	$ENV{LANG}="en_GB.utf8";
	unless (-f "$dir/bin/pg_ctl")
	{
		die "Pas de binaire $dir/bin/pg_ctl\n";
	}
	my $pgdata="$dir/data";
	$ENV{PGDATA}=$pgdata;
	my $args;
	if (compare_versions($version,'8.0')==-1) # Plus vieille qu'une 8.0
	{
		$args="-c wal_sync_method=fdatasync -c shared_buffers=128000 -c sort_mem=32000 -c vacuum_mem=32000 -c checkpoint_segments=32";
	}
	else
	{
		$args="-c wal_sync_method=fdatasync -c shared_buffers=1GB -c work_mem=32MB -c maintenance_work_mem=1GB -c checkpoint_segments=32";
	}
	if (! -d $pgdata)
	{ # Création du cluster
		system_or_die("$dir/bin/initdb");
		system_or_die("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
		system_or_die("$dir/bin/createdb"); # Pour avoir une base du nom du dba (/me grosse feignasse)
	}
	else
	{
		system_or_die("$dir/bin/pg_ctl -w -o '$args' start -l $pgdata/log");
	}
}

sub stop
{
	my ($version,$mode)=@_;
	if (not defined $mode)
	{
		$mode = 'fast';
	}
	my $dir=dest_dir($version);
	my $pgdata="$dir/data";
	return 1 unless (-e "$pgdata/postmaster.pid"); #pg_ctl aime pas qu'on lui demande d'éteindre une instance éteinte
	$ENV{PGDATA}=$pgdata;
	system_or_die("$dir/bin/pg_ctl -w -m $mode stop");
}

sub git_update
{
	system_or_die ("cd ${git_local_repo} && git pull");
}

# La conf est dans un fichier à la .ini. Normalement /usr/local/etc/postgres_manage.conf, 
# ou ~/.postgres_manage.conf ou pointée par la variable d'env
# postgres_manage, et sinon, passée en ligne de commande. Les priorités sont évidemment ligne de commande avant environnement
# avant rep par défaut

sub charge_conf
{
	# On détecte l'endroit d'où lire la conf:
	unless (defined $conf_file)
	{
		# Pas de fichier en ligne de commande. On regarde l'environnement
		if (defined $ENV{postgres_manage})
		{
			$conf_file=$ENV{postgres_manage};
		}
		else
		{
			if (-e ($ENV{HOME} . "/.postgres_manage.conf") )
			{
				$conf_file=($ENV{HOME} . "/.postgres_manage.conf");
			}
			else
			{
				if (-e "/usr/local/etc/postgres_manage.conf")
				{
					$conf_file="/usr/local/etc/postgres_manage.conf";
				}
			}
		}
	}

	unless (defined $conf_file) 
	{
		die "Pas de fichier de configuration trouvé, ni passé en ligne de commande (-conf), ni dans \$postgres_manage,\nni dans " . $ENV{HOME} . "/.postgres_manage.conf, ni dans /usr/local/etc/.postgres_manage.conf\n";
	}

	# On cherche 4 valeurs: parallelisme, work_dir, doxy_file et git_local_repo.
	open CONF,$conf_file or die "Pas pu ouvrir $conf_file:$!\n";
	while (my $line=<CONF>)
	{
		no strict 'refs'; # Pour pouvoir utiliser les références symboliques
		my $line_orig=$line;
		$line=~ s/#.*//; # Suppression des commentaires
		$line =~ s/\s*$//; # suppression des blancs en fin de ligne
		next if ($line =~ /^$/); # On saute les lignes vides après commentaires
		$line =~ s/\s*=\s*/=/; # Suppression des blancs autour du =
		# On peut maintenant traiter le reste avec une expression régulière simple :)
		$line =~ /(\S+)=(.*)/ or die "Ligne de conf bizarre: <$line_orig>\n";
		my $param_name=$1; my $param_value=$2;
		${$param_name}=$param_value; # référence symbolique, par paresse.
	}
	die "Il me manque des paramètres dans la conf" unless (defined $parallelisme and defined $work_dir and defined $git_local_repo and defined $doxy_file);
	unless (defined $CONFIGOPTS)
	{
		$CONFIGOPTS='--enable-thread-safety --with-openssl --with-libxml --enable-nls --enable-debug';#Valeur par défaut
	}
	close CONF;
}

GetOptions ("version=s" => \$version,
	    "mode=s" => \$mode,
	    "conf_file=s" => \$conf_file,)
         or die("Error in command line arguments\n");

if (not defined $version and (not defined $mode or $mode !~ /list|rebuild_latest|git_update/))
{
	if (defined $ENV{pgversion})
	{
		$version=$ENV{pgversion};
	}
	else
	{
		die "Il me faut une version (option -version, ou bien variable d'env pgversion\n";
	}
}

charge_conf();

# Bon j'aurais pu jouer avec des pointeurs sur fonction. Mais j'ai la flemme
if (not defined $mode)
{
	die "Il me faut un mode d'execution: option -mode, valeurs: env,....\n";
}
elsif ($mode eq 'env')
{
	env();
}
elsif ($mode eq 'build')
{
	build($version);
}
elsif ($mode eq 'build_postgis')
{
	build_postgis($version);
}
elsif ($mode eq 'start')
{
	start($version);
}
elsif ($mode eq 'stop')
{
	stop($version);
}
elsif ($mode eq 'clean')
{
	clean($version);
}
elsif ($mode eq 'list')
{
	print join("\n",@{list()}),"\n";
}
elsif ($mode eq 'list_avail')
{
	print join("\n",@{list_avail()}),"\n";
}
elsif ($mode eq 'list_latest')
{
	print join("\n",@{ls_latest()}),"\n";
}
elsif ($mode eq 'rebuild_latest')
{
	rebuild_latest();
}
elsif ($mode eq 'git_update')
{
	git_update();
}
elsif ($mode eq 'doxy')
{
	doxy($version);
}
else
{
	die "Mode $mode inconnu\n";
}
