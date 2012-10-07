###############################################################################
#     DESscrobbler for xmms2 - scrobble the songs played in xmms2 to last.fm
#     Copyright (C) 2012  David Santiago
#  
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
##############################################################################



#!/usr/bin/perl
use warnings;
use strict;
use utf8;
use diagnostics;
use 5.014;
use Audio::XMMSClient;
use Data::Dumper;
use threads;
use threads::shared;
require LWP::UserAgent;
use JSON;
use Digest::MD5 qw(md5_hex);

use constant API_KEY=> '80fb0e02fcb491adb56239345a9f4e0e';
use constant SECRET=> '0c4a7148616dc5eb9738a83219579af7';

#change this command to reflect a browser in your system
use constant BROWSER_CMD=>"uzbl-browser 'http://www.last.fm/api/auth/?api_key=%s&token=%s'";
use constant WS_URL => 'http://ws.audioscrobbler.com/2.0/';


my $freezetime : shared = 0;
my $http = LWP::UserAgent->new;


#performs the authentication in the last.fm website.
#This method performs the 3 steps:
#1- get the token
#2- Ask user to confirm
#3- get the session key
sub authenticate{
  
  my $auth_url = shift;
  my %params = ('method'=>'auth.getToken', 'api_key'=> API_KEY, 'format'=>'json');
  
  
  my $url = _get_url( $auth_url, \%params);
  
  #1- get token
  my $response = $http->get($url);
  
  if($response->is_success){
    
    my $results_ref = decode_json $response->content;
    my %results = %$results_ref;
    
    my $token = $results{'token'};
    
    #2- ask the user to authorize application
    system(sprintf(BROWSER_CMD, API_KEY, $token));
    
    
    #3- finish authentication by getting the session key
    %params=('method'=>'auth.getSession','api_key'=> API_KEY, 'token'=>$token,'format'=>'json',
	     'api_sig'=>_get_signature(('token',$token,
					'method','auth.getSession',
					'api_key', API_KEY)));
    
    $url = _get_url($auth_url, \%params);
    
    $response = $http->get($url);
    
    if($response->is_success){
      
      say "Authentication Successfull!";
      
      $results_ref=decode_json($response->content);
      %results = %$results_ref;
      
      
      return ($results{'session'}{'subscriber'}, $results{'session'}{'name'}, $results{'session'}{'key'}, $token);
      
      
    }else{
      die $response->status_line;
    }
    
  }else {
     die $response->status_line;
  }
  
  
}

# method that generates an URL for the "read" methods as described in the developers page.
sub _get_url{
  
  my $url = shift;
  my $params_ref = shift;
  
  my %params = %$params_ref;
  
  my $i=0;
  for my $key (keys %params){
    if($i==0){
      $url.="?$key=$params{$key}";
      $i+=1;
    }else{
      $url.="&$key=$params{$key}";
    }
  }
  
  $url=~ s/ /+/g;
  return $url;
  
}


# gets a new xmms2 client
sub get_new_client{

  my $clientName = shift @_;

  # To communicate with xmms2d, you need an instance of the
  # Audio::XMMSCLient class, which abstracts the connection.  First you
  # need to initialize the connection; as argument you need to pass
  # "name" of your client. The name has to be in the range [a-zA-Z0-9]
  # because xmms is deriving configuration values from this name.

  my $xmmsClient = Audio::XMMSClient->new($clientName);

  # Now we need to connect to xmms2d. We need to pass the XMMS ipc-path to the
  # connect call.  If passed None, it will default to $ENV{XMMS_PATH} or, if
  # that's not set, to unix:///tmp/xmms-ipc-<user>

  if (!$xmmsClient->connect) {
    printf STDERR "Connection failed: %s\n", $xmmsClient->get_last_error;
    exit 1;
  }

  # This is all you have to do to connect to xmms2d. 


  return $xmmsClient;

}

# Method that deals with the song change on xmms2
sub playback_song_change{

  my $client = shift;
  my $playbacktime=0;
  my ($subscriber, $name, $session_key, $token)= authenticate( WS_URL);

    #The data we're going to collect
    my $music_track_number = ''  ; # Music's track number
    my $music_artist       = ''  ;# Music's artist
    my $music_album        = ''  ;# Music's album
    my $music_title        = ''  ;# Music's title

  
  while(1){

    $playbacktime=time;
  
    # The result of the  calls made to the xmms2 daemon
    my $result;
    
    # Hash that represetns the songs metadata
    my %song_metadata;
    
    # The song position in the current list of the xmms2 daemon
    my $song_position;



    #Waits for the song to change
    $result = $client->broadcast_playback_current_id();
    $result->wait();
    
    
    if((time - $playbacktime - $freezetime)>30 &&
       $music_title ne '' &&
       $music_artist ne ''){
      
      scrobble_song(WS_URL, ('api_key', API_KEY,
			    'token',$token,
			    'trackNumber', $music_track_number,
			    'artist',$music_artist,
			    'album', $music_album,
			    'track',$music_title,
			    'sk', $session_key,
			    'timestamp',$playbacktime));
    
    }
    
    $freezetime=0;
    
    #Get the current song id
    $result = $client->playback_current_id();
    $result->wait();
    $song_position = $result->value();

    
    $result = $client->playback_playtime();
    
    #gets the current song's metadata
    $result = $client->medialib_get_info( $song_position );
    $result->wait();
    my $song_metadata_ref = $result->value();

    
    %song_metadata = %{ $song_metadata_ref};

    $music_track_number = '';        # Music's track number
    $music_artist       = '';        # Music's artist
    $music_album        = '';        # Music's album
    $music_title        = '';        # Music's title

    
    foreach my $key (keys %song_metadata){
       my %song_info = %{$song_metadata{$key} };

       # variable that will contain the associated value. It's required because the value we want is associated to the input source plugin
       # (vorbis, mp3, flac...) and we don't know what plugin is.
       my $music_metadata_source_value=$song_info{(keys %song_info)[0]};

       given($key){
	 when($_ eq 'artist'){ $music_artist= $music_metadata_source_value; $music_artist =~ s/_/ /; break;}
	 when($_ eq 'title'){ $music_title = $music_metadata_source_value; $music_title =~ s/_/ /; break;}
	 when($_ eq 'album'){ $music_album = $music_metadata_source_value; $music_album =~ s/_/ /; break;}
	 when($_ eq 'tracknr'){ $music_track_number = $music_metadata_source_value; break;}
	 default {}
       }

    }
    
    
    
    print "\n'$music_artist': '$music_title' (album: '$music_album', track: '$music_track_number') ";
    $|=1;#force the flush of the previous print
    
    if($music_artist ne '' && $music_title ne '' ){
      
      threads->create('now_playing_song', WS_URL, ('api_key', API_KEY,
						    'token',$token,
						    'trackNumber',$music_track_number,
						    'artist',$music_artist,
						    'album',$music_album,
						    'track',$music_title,
						    'sk', $session_key));
      
#      now_playing_song(WS_URL,('api_key', API_KEY,
#			       'token',$token,
#			       'trackNumber',$music_track_number,
#			       'artist',$music_artist,
#			       'album',$music_album,
#			       'track',$music_title,
#			       'sk', $session_key));
    }
    

  }
  
}


sub _get_signature{
  
  my %parameters = @_;
  
  my $string='';
  
  #say Dumper(%parameters);
  
  for my $key (sort keys %parameters){
    $string.=$key . $parameters{$key};
  }
  $string.=SECRET;
  return md5_hex($string);
  
}

sub send_post_request{
  
  my $url = shift;
  my %parameters = @_;

  $parameters{'format'}='json';

  my %post_params = ('content'=>\%parameters);
  
  my $response = $http->post($url, %post_params);
  
  if($response->is_success){
    
    #say Dumper(decode_json ($response->content));
    return 1;
    
    #say $response->content;
    #return decode_json $response->content;
    
  }else{
    say $response->content;
    return -1;
  }
}


sub scrobble_song{
  
  my $url = shift;
  my %parameters = @_;
  
  $parameters{'method'}='track.scrobble';
  $parameters{'api_sig'}=_get_signature(%parameters);
 
  if(send_post_request( $url, %parameters)==1){
    say "Scrobble OK";
  }else{
    say "Error scrobbling!";
    
  }
}


sub now_playing_song{
  
  my $url = shift;
  my %parameters = @_;
  
  $parameters{'method'}='track.updateNowPlaying';
  $parameters{'api_sig'}=_get_signature(%parameters);
 
  if(send_post_request( $url, %parameters)==1){
    print "NowPlaying OK ";
  }else{
    print "Error NowPlaying! ";
    
  }  
}

sub playback_status_change{
 
  my $client= shift;
  my $stoptime=0;
 
  while(1){
    
    # The result of the  calls made to the xmms2 daemon
    my $result;

    #Waits for the song to change
    $client->broadcast_playback_status()->wait();
    
    $result = $client->playback_status();
    $result->wait();
    my $status=$result->value;
    
    #status==2 -> paused
    #status==1 -> playing
    #status==0 -> stopped
    
    given($status){
      when($_ == 1){
	$freezetime+=time-$stoptime;
		    
	break;	    
      }
      default{$stoptime=time;}
    } 
  } 
}

my $client1 = get_new_client('status_change');
my $client2 = get_new_client('song_change');
  
my $playback_status_change_thread = threads->create('playback_status_change', $client1);
my $playback_song_change_thread = threads->create('playback_song_change', $client2);



$playback_status_change_thread->join();
$playback_song_change_thread->join();


