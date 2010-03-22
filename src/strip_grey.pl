#!/usr/bin/perl
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.
#
# Delete (turn into white) each lightgrey pixels (r=g=b) inside the whole image.
# As a second pass, delete single isolated (with white around) pixels.
#
# Usage: $0 [input-file] [output-file]
# Debian users: apt-get install perlmagick

use strict;
use Image::Magick;

# Range [0..65535]
use constant GREY_LEVEL => 15500;

sub is_pixel_white {
	my($pixel) = shift;
	my($red, $green, $blue, $opacity) = split ",", $pixel;
	return (($red == 65535) and ($green == 65535) and ($blue == 65535));
}

##
# Main
##
my $image = new Image::Magick;
my $x;

if ($#ARGV == -1) {
	$x = $image->Read(file => \*STDIN);
} else {
	$x = $image->Read("$ARGV[0]");
}

die "$x" if "$x"; # print the error message

my($width, $height) = $image->Get('width', 'height'); 

# List of colors to remove (one color is one string)
my(@lightgrey_colors) = ();
my @histogram = $image->Histogram();

while (@histogram) {
	my($red, $green, $blue, $opacity, $count) = splice(@histogram, 0, 5);

	# example: "53713,53713,53713,0" (r,g,b,a)
	push(@lightgrey_colors, join(',', ($red, $green, $blue, $opacity))) if ($red > GREY_LEVEL);
}

for (my $i = 0; $i < $width; $i++) {
	for (my $j = 0; $j < $height; $j++) {
		my $color = $image->Get("pixel[$i,$j]");
		if (grep {$_ eq $color} @lightgrey_colors) {
			$image->Set("pixel[$i,$j]" => 'white');
		}
	}
}

# Delete isolated points
for (my $i = 1; $i < ($width-1); $i++) {
	for (my $j = 1; $j < ($height-1); $j++) {

		unless (is_pixel_white $image->Get("pixel[$i,$j]")) {
                        my $i2 = $i + 1;
                        my $i3 = $i - 1;
                        my $j2 = $j + 1;
                        my $j3 = $j - 1;

                        # Test the 8 pixels around
			if ((is_pixel_white $image->Get("pixel[$i2,$j]")) and
					(is_pixel_white $image->Get("pixel[$i3,$j]")) and
					(is_pixel_white $image->Get("pixel[$i2,$j2]")) and
					(is_pixel_white $image->Get("pixel[$i3,$j2]")) and
					(is_pixel_white $image->Get("pixel[$i2,$j3]")) and
					(is_pixel_white $image->Get("pixel[$i3,$j3]")) and
					(is_pixel_white $image->Get("pixel[$i,$j2]")) and
					(is_pixel_white $image->Get("pixel[$i,$j3]"))) {
                                $image->Set("pixel[$i,$j]" => 'white');
			}
		}
	}
}

if ($#ARGV > 0) {
	$image->Write(filename => "$ARGV[1]", compression => 'None');
} else {
	binmode STDOUT;
	$image->Write('png:-');
}

undef $image;
exit 0;
