use strict;
use warnings;
use utf8;
use Encode;
use DBIx::Simple;

package Unaubot;
our $version = '3.02';

use FindBin;

sub dog {
    my $dog;
    my $class_name = shift;
    die "missing class name" if ! defined $class_name;
    {
        my $class = "Unaubot::Dog::$class_name";
        no strict 'refs';
        eval '$dog = new '.$class.'(@_)';
        die "failed to create a new instance of $class:\n $@" if $@;
    }
    my $base_dir = $FindBin::Bin;
    my $config = do {
        use YAML::Tiny;
        my $c = YAML::Tiny->read("$base_dir/config.yaml");
        $c->[0];
    };
    $dog->config($config);
    $config->{base_dir} = $base_dir;
    return $dog;
}

sub config {
    my $self = shift;
    @_ ? $self->{config} = shift : $self->{config};
}

sub db {
    my $self = shift;
    @_ ? $self->{db} = shift : $self->{db};
}

sub import {
    no strict 'refs';
    my $caller = caller;
    foreach my $sym (qw/dog/) {
        *{$caller."::$sym"} = *{$sym};
    }
}

package Unaubot::Dog;
use base qw/Unaubot/;
use Net::Twitter;

sub new {
    my $class = shift;
    bless {}, $class;
}

sub fire {
    my $self = shift;
    $self->initialize();
    $self->start();
    $self->finalize();
}

sub initialize {
    my $self = shift;
    my $config = $self->config;
    my $base_dir = $config->{base_dir};
    my $db_name = $config->{database};
    my $db = DBIx::Simple->connect("dbi:SQLite:dbname=$base_dir/$db_name")
        or die DBIx::Simple->error;
    $self->db($db);
}


sub finalize {
    my $self = shift;
    $self->db->disconnect;
}

package Unaubot::Dog::Collecter;
use base qw/Unaubot::Dog/;
use Encode;

sub start {
    my $self = shift;
    
    my $nt = Net::Twitter->new();
    my $own_name = $self->config->{my_name};
    my $db = $self->db;

    my $rs = $db->select('search_word', ['id', 'word', 'since_id']);
    while (my $row = $rs->hash) {
        my $word = decode_utf8($row->{word});
        my $search_word_id = $row->{id};
        my $since_ID = $row->{since_id};
        my $response = $nt->search({q => $word, since_id => $since_ID});
        my @results = reverse(@{$response->{results}}); # 
        # my $size = scalar @results;
        for my $result (@results) {
            my $from_user = $result->{from_user};
            next if $from_user eq $own_name;
            my $text = $result->{text};
            my $status_ID = $result->{id};
            my $tweet = $self->reply($text, $from_user);
            next if ! defined $tweet;
            $db->insert('tweet', {text => $tweet});
            $since_ID = $status_ID;
        }
        $db->update('search_word', {since_id => $since_ID},{id => $search_word_id});
        #warn encode_utf8("$word: $size : $since_ID");
    }
    
}

sub reply {
    my $self = shift;
    my ($text, $user) = @_;
    my $is_japanese = 0;
    if ($text =~ qr{\p{inHiragana}}xms) {
        $is_japanese = 1;
    }
    elsif  ($text =~ qr{\p{inKatakana}}xms) {
        $is_japanese = 1;
    }
    elsif  ($text =~ qr{\p{inCJKUnifiedIdeographs}}xms) {
        $is_japanese = 1;
    }
    return if ! $is_japanese;
    my $pre = ($text =~ qr{unaubot|うなうぼっと}xms) ? '褒め言葉？' :
              ($text =~ qr{bot|ボット}xms) ? 'bot です' :
              ($text =~ qr{反応}xms)      ? 'そうなんです' : 'つい反応' ;
    my $tweet = "$pre QT \@$user $text";
    if (length($tweet) > 140) {
        $tweet = substr($tweet, 0, 140 -3) . '...';
    }
    return $tweet;
}

package Unaubot::Dog::Tweeter;
use base qw/Unaubot::Dog/;
use Encode;

sub start {
    my $self = shift;
    
    my $config = $self->config;
    my $nt = Net::Twitter->new(traits => ['API::REST', 'OAuth'],
                             consumer_key => $config->{consumer_key},
                             consumer_secret => $config->{consumer_key_secret},
    );
    $nt->access_token($config->{access_token});
    $nt->access_token_secret($config->{access_token_secret});

    my $db = $self->db;
    my $rs = $db->query('select id, text from tweet order by id');
    while (my $row = $rs->hash) {
        my $tweet_id = $row->{id};
        my $tweet = decode_utf8($row->{text});
        eval {
            $nt->update($tweet);
            warn encode_utf8($tweet);
        };
        $db->delete('tweet', {id => $tweet_id});
    }
}

1;
