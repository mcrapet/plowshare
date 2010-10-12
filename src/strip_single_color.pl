#!/usr/bin/perl
#
# Delete (turn into white) each pixel which have a unique color inside the whole image
# Copyright (c) 2010 Matthieu Crapet
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

# Usage: $0 [input-file] [output-file]
# Debian users: apt-get install perlmagick

use strict;
use Image::Magick;

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
my(@uniqcolors) = ();
my @histogram = $image->Histogram();

while (@histogram) {
	my($red, $green, $blue, $opacity, $count) = splice(@histogram, 0, 5);

	# example: "43433,16962,49858,0" (r,g,b,a)
	push(@uniqcolors, join(',', ($red, $green, $blue, $opacity))) if ($count == 1);
}

for (my $i = 0; $i < $width; $i++) {
	for (my $j = 0; $j < $height; $j++) {
		my $color = $image->Get("pixel[$i,$j]");
		if (grep {$_ eq $color} @uniqcolors) {
			$image->Set("pixel[$i,$j]" => 'white');
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
