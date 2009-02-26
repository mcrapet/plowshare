#!/usr/bin/python
import string
import glob
import os
import sys
from StringIO import StringIO


# Third-party modules
from PIL import Image, ImageFont, ImageDraw

def debug(line, linefeed=True):
    """Write line to standard error."""
    sys.stderr.write(str(line)+("\n" if linefeed else ""))
    sys.stderr.flush()
    
def get_at(lst, nfield):
    """Return nfield of lst."""
    return [x[nfield] for x in lst]

def substract_images(i1, i2, pos1):
    """Substract (XOR) i2 from i1 and return a new image."""
    i3 = i1.copy()
    ip1, ip2, ip3 = map(load_pixels, [i1, i2, i3])
    width1, height1 = i1.size
    width2, height2 = i2.size
    ox, oy = pos1
    for x in range(min(width2, width1 - ox)):
        for y in range(min(height2, height1 - oy)):
            val1 = ip1[ox+x, oy+y]
            val2 = ip2[x, y]
            ip3[ox+x, oy+y] = (255 if val1 == val2 else 0)
    return i3

def load_pixels(image):
    """Load pixel-access object for image"""
    ipimage = image.load()
    if image.im: 
        # A hack, http://osdir.com/ml/python.image/2008-03/msg00011.html
        return image.im.pixel_access(image.readonly)
    return ipimage
        
def compare_images(i1, i2):
    """Compare two images and return difference error."""
    ip1, ip2 = map(load_pixels, [i1, i2])
    width, height = i1.size
    error = 0
    for x in range(width):
        for y in range(height):
            val1 = ip1[x, y]
            val2 = ip2[x, y]
            error += (1.0 if val1 != val2 else 0.0)
    return float(error) / (width * height)
    
def open_image(path):
    """Open image and return a B&W PIL.Image object.""" 
    transform = lambda x: (x != 0) and 255 or 0
    image = Image.open(path).convert("L").point(transform)
    return image

def crop_image(image, box=None):
    """Return cropped image."""
    return image.crop(box)
        
def autocrop_image(image):
    """Return a cropped image."""
    return crop_image(image, image.getbbox())

def build_chars(fontfile, fontsize, excluded_chars):
    """Return a dictionary of (char, image) pairs for [A-Z0-9]."""
    font = ImageFont.truetype(fontfile, fontsize)
    chars = {}
    for char in string.uppercase + string.digits:
        if char in excluded_chars:
            continue
        image = Image.new("L", (2*fontsize, 2*fontsize), 0)
        draw = ImageDraw.Draw(image)    
        draw.text((0, 0), char, font=font, fill=255)
        chars[char] = autocrop_image(image)
    return chars

def invert_image(image):
    """Invert B&W image."""
    return image.point(lambda x: (0 if x else 255))

def rotate_and_crop(image, angle):
    """Rotate, crop and invert an image."""
    return invert_image(autocrop_image(image.rotate(angle, expand=True)))

def get_errors(image, chars, zones):
    """Compare an image against a dictionary of chars."""
    image_width, image_height = image.size
    for char, char_image in sorted(chars.iteritems(), key=lambda (k, v): k):
        debug(".", linefeed=False)
        for (xstart, xend), (angle_start, angle_end) in zones: 
            for angle in range(angle_start, angle_end+1, 1):
                char_image_rotated = rotate_and_crop(char_image, angle)
                char_width, char_height = char_image_rotated.size
                y = max(0, (image_height - char_height) / 2)
                for x in range(xstart, xend+1, 1):
                    cropped_image = crop_image(image, 
                        (x, y, x+char_width, y+char_height))
                    error = compare_images(char_image_rotated, cropped_image)
#                    print error, char, (x, y), angle
#                    print_image(substract_images(image, char_image_rotated, (x, y)))
#                    sys.stdin.read(1)
                    yield (error, char, (x, y), angle)
    debug("")

zones = [
    [(0, 10), (-35, -20)],
    [(15, 25), (20, 35)],
    [(30, 40), (-35, -20)],
    [(45, 55), (20, 35)],
]

def print_image(image, step=1, outputfd=sys.stderr):
    """Print image to outputfd (standard error by default)."""
    ip = image.load()
    width, height = image.size
    for y in range(0, height, step):
        for x in range(0, width, step):
            outputfd.write("*" if ip[x, y] == 0 else " ")
        outputfd.write("\n")
    outputfd.flush()
            
def decode_megaupload_captcha(captcha_imagefile, fontfile):
    """Return decoded captcha string."""            
    captcha_length = 4
    chars = build_chars(fontfile, 36, excluded_chars="1IL")
    image = open_image(captcha_imagefile)
    print_image(image, 2)
    result = []
    while len(result) < captcha_length:
        debug("start iteration %d/%d " % (len(result)+1, captcha_length), False)
        errors = list(sorted(get_errors(image, chars, zones)))
        #debug(errors[:5])
        max_info = errors[0]
        #max_info = min(get_errors(image, chars))
        result.append(max_info)
        print max_info
        min_error, char, pos, angle = max_info
        x, y = pos        
        for index, ((xstart, xend), (angle_start, angle_end)) in enumerate(zones):
            if xstart <= x <= xend:
                del zones[index]
                break
        char_image_rotated = rotate_and_crop(chars[char], angle)
        image = substract_images(image, char_image_rotated, pos)
        print_image(image, 2)
        
    sorted_by_position = sorted(result, key=lambda x: x[2])
    errors = sum(get_at(sorted_by_position, 0)) / 4.0
    captcha = "".join(s[0] for s in get_at(sorted_by_position, 1)).upper()
    debug((errors, captcha))
    return captcha
    
if __name__ == '__main__':
    captcha_file = StringIO(open(sys.argv[1]).read())
    fontfile = os.path.join(os.path.dirname(sys.argv[0]), "news_gothic_bt.ttf")
    print sys.exit(decode_megaupload_captcha(captcha_file, fontfile))
