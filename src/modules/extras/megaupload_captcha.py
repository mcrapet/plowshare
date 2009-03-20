#!/usr/bin/python
"""
Decode the captcha being currently used by Megaupload (2009/03/20).
"""
import string
import sys
import subprocess
import os
import tempfile
from itertools import tee, izip
from operator import itemgetter
from StringIO import StringIO

# Third-party modules
import PIL.Image as Image

DEBUG = True

# Generic functions

def debug(line="", linefeed=True, stream=sys.stderr):
    """Write line to standard error."""
    if DEBUG:
        stream.write(str(line)+("\n" if linefeed else ""))
        stream.flush()

def load_psyco():
    """Enabled psyco if module is installed."""
    try:
        import psyco
        psyco.full()
        return True
    except ImportError:
        pass        

def replace_chars(s, table):
    """Use dictionary table to replace chare in s."""
    for key, value in table.iteritems():
        s = s.replace(key, value)
    return s

def center_of_mass(coords):
    """Return center of mass of coordinates"""
    return [sum(lst)/len(lst) for lst in zip(*coords)]

def pairwise(iterable):
    "s -> (s0,s1), (s1,s2), (s2, s3), ..."
    a, b = tee(iterable)
    b.next()
    return izip(a, b)
  
def module2(vector):    
    """Return module^2 of vector"""
    return sum((x*x) for x in vector)

def distance2(vector1, vector2):    
    """Return module^2 of vector"""
    return module2((a-b) for (a, b) in zip(vector1, vector2))

def binary(n):
    """Return array containing binary digits of n (LSB)."""
    return n > 0 and [n & 1] + binary(n >> 1) or []

def union_sets(sets):
    """Return union of sets."""
    return reduce(set.union, sets)

def segment(seq, k):
    """Return a segmentation of elements in seq in groups of k."""
    if k > 1:
        for length in range(1, (len(seq)-k+1)+1):
            for x in segment(seq[length:], k-1):
                yield (seq[:length],) + x  
    else: yield (seq,)

def run(command, inputdata=None):
    """Run a command and return standard output"""
    pipe = subprocess.PIPE
    popen = subprocess.Popen(command, stdout=pipe, stderr=pipe)
    outputdata = popen.communicate(inputdata)[0]
    assert (popen.returncode == 0), "Error running: %s" % command
    return outputdata

def ocr(image):
    """OCR an image and return text"""
    temp_tif = tempfile.NamedTemporaryFile(suffix=".tif")
    temp_txt = tempfile.NamedTemporaryFile(suffix=".txt")
    image.save(temp_tif, format="TIFF")
    run(["tesseract", temp_tif.name, os.path.splitext(temp_txt.name)[0]])
    return open(temp_txt.name).read().strip()

def histogram(it):
    """Return sorted (ascendent) histogram of elements in iterator."""
    ocurrences = {}
    for x in it:
        ocurrences[x] = ocurrences.get(x, 0) + 1
    return list(sorted(ocurrences.iteritems(), key=lambda (k, v): v))
 
# Generic PIL functions

def smooth(image0, value):
    """Smooth image spreading values of a pixel."""
    image = image0.copy()
    ipimage0 = image0.load()
    ipimage = image.load()
    width, height = image.size
    for x, y in iter_image(image):
        if ipimage0[x, y] == value:
            if x+1 < width:            
                ipimage[x+1, y] = value
            if y+1 < height:
                ipimage[x, y+1] = value
    return image            

def set_pixels(image0, pixels, value):
    """Set pixels in image to given value and return new image."""
    image = image0.copy()    
    ipimage = image.load()
    for (x, y) in pixels:
        ipimage[x, y] = value
    return image

def floodfill_image(image0, (x, y), fill_color, threshold=0):
    """Flood fill image with fill color in given position.    
    Return filled image and pixels that have been filled.
    
    See http://mail.python.org/pipermail/image-sig/2005-September/003559.html
    """    
    image = image0.copy()    
    width, height = image.size
    def get_color_distance(p1, p2):
        """Return color distance between value p1 and p2.""" 
        return abs(p1-p2)
    def is_within((x, y)):
        """Return True if  (x, y) is inside image"""
        return (0 <= x < width and 0 <= y < height)
    ipimage = image.load()
    background_value = ipimage[x, y]
    ipimage[x, y] = fill_color
    edge = [(x, y)]
    filled = set(edge)
    while edge:
        newedge = []
        for x, y in edge:
            for s, t in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
                if (s, t) in filled or not is_within((s, t)): 
                    continue
                pixel = ipimage[s, t]
                if get_color_distance(pixel, background_value) <= threshold:
                    ipimage[s, t] = fill_color
                    newedge.append((s, t))
        filled.update(newedge)
        edge = newedge
    return image, filled
              
def iter_image(image):
    """Yield (x, y) pairs to walk an image positions."""
    w, h = image.size
    return ((x, y) for x in range(w) for y in range(h))

def get_zones(image, seen0, value, minpixels=1):
    """
    Scan an image and return groups of pixels with a given value 
    having the same color. Ignore pixels already found in seen.
    Ignore groups with less thatn minpixels.
    """     
    seen = seen0.copy()
    pixels = image.load()
    zones = []
    for x, y in iter_image(image):
        if (x, y) not in seen and pixels[x, y] == value:
            filled = floodfill_image(image, (x, y), 50)[1]                
            if len(filled) > minpixels:
                zones.append(filled)
                seen.update(filled)
    return zones              

def autocrop_image(image):
    """Return an automatically cropped image."""
    return image.crop(image.getbbox())
 
def new_image_from_pixels(pixels, value):
    """Return an image from a group of pixels (remove offset)."""       
    x1 = min(pixels, key=itemgetter(0))[0] 
    y1 = min(pixels, key=itemgetter(1))[1]
    x2 = max(pixels, key=itemgetter(0))[0]
    y2 = max(pixels, key=itemgetter(1))[1]
    image = Image.new("L", (x2-x1+1, y2-y1+1), 255)
    ipimage = image.load()
    for (x, y) in pixels:
        ipimage[x-x1, y-y1] = value 
    return image

### Megaupload captcha decoder

def filter_word(word0):
    """Check if a word is a valid captcha (try also to make 
    some basic corrections)."""
    digit_to_letter = {        
        "1": "T",
        "2": "Z",
        "4": "A",
        "5": "S",
        "6": "G",
        "7": "T",
        "8": "B",
    }        
    letter_to_letter = {
        "{": "C",
        "(": "C",
        "[": "C",
        "I": "C",
    }
    allowed_chars = string.uppercase + string.digits
    letter_to_digit = dict((v, k) for (k, v) in digit_to_letter.items())
    wordlst1 = [c for c in word0.upper() if c != " "]
    if len(wordlst1) != 4:
        return    
    wordlst2 = [replace_chars(replace_chars(w, digit_to_letter), 
        letter_to_letter) for w in wordlst1[:3]] + \
        [replace_chars(wordlst1[3], letter_to_digit)]
    wordlst = [c for c in wordlst2 if c in allowed_chars]    
    if len(wordlst) != 4:
        return        
    if wordlst[0] not in string.uppercase or wordlst[1] not in string.uppercase \
            or wordlst[2] not in string.uppercase or wordlst[3] not in string.digits:
        return
    return "".join(wordlst)

def get_error(pixels_list, image):
    """Return error for a given pixels groups compared 
    to the expected positions."""
    width, height = image.size
    width8 = width / (2*4.0)
    error = 0.0
    for n, pixels in enumerate(pixels_list):    
        com_x, com_y = center_of_mass(pixels)
        error += distance2((com_x, com_y), ((2*n+1)*width8, (height/2.0)))
    return error

def get_pair_inclussion(seq, value, pred=None):
    """Given a sequence find the boundaries of value."""
    if pred is None:
        pred = lambda x: x
    for val1, val2 in pairwise(seq):
        if pred(val1) <= value <= pred(val2):
            return val1, val2

def join_images((width, height), images):
    """Join images to build a new image with (width, height) size."""
    gimage = Image.new("L", (width, height), 255)        
    x = 0
    for image in images:
        w, h = image.size
        gimage.paste(image, (x, (height -h)/2))
        x += w
    return gimage

def build_candidates(characters4_pixels_list, uncertain_pixels, 
        rotation=22):
    """Build word candidates from characters and uncertains groups."""       
    for plindex, characters4_pixels in enumerate(characters4_pixels_list):
        debug("Generating words (%d) %d/%d: " % 
            (2**len(uncertain_pixels), plindex+1, len(characters4_pixels_list)), 
            False)
        for index in range(2**len(uncertain_pixels)):
            characters4_pixels_test = [x.copy() for x in characters4_pixels] 
            for active, pixels in zip(binary(index), uncertain_pixels):        
                if active:
                    pair = get_pair_inclussion(characters4_pixels_test, 
                        center_of_mass(pixels)[0],
                        pred=lambda x: center_of_mass(x)[0])
                    if not pair:
                        continue
                    char1, char2 = pair
                    char1.update(pixels)
                    char2.update(pixels)
            images = []
            for cindex, pixels in enumerate(characters4_pixels_test):
                image = new_image_from_pixels(pixels, 1)
                angle = rotation * (+1 if (cindex % 2 == 0) else -1)
                rotated_image = image.rotate(angle, expand=True)
                image2 = rotated_image.point(lambda x: 0 if x == 1 else 255)
                images.append(image2)        
            width = sum(i.size[0] for i in images)
            height = max(i.size[1] for i in images)
            clean_image = smooth(join_images((width, height), images), 0)
            #clean_image.save("out%03d.png" % index)
            text = ocr(smooth(clean_image, 0))
            filtered_text = filter_word(text)
            #debug("%s -> %s" %(text, filtered_text))
            if filtered_text:
                yield filtered_text
            debug(".", linefeed=False)
        debug()

def decode_megaupload_captcha(original, maxiterations=None):
    """Decode a Megaupload catpcha image 
    
    Expected 4 letters (LETTER LETTER LETTER NUMBER), rotated and overlapped"""
    width, height = original.size
    image = Image.new("L", (width+2, height+2), 255)
    image.paste(original, (1, 1))
    background_pixels = floodfill_image(image, (0, 0), 155)[1]
    debug("Background pixels: %d" % len(background_pixels))
    
    characters_pixels = sorted(get_zones(image, background_pixels, 0, 20),
        key=center_of_mass)
    debug("Characters: %d - %s" % (len(characters_pixels), 
        [len(x) for x in characters_pixels]))    
    assert len(characters_pixels) >= 4, "Cannot find 4 characters in image"
    characters_pixels_list0 = [[union_sets(y) for y in x] 
        for x in segment(characters_pixels, 4)]
    
    characters4_pixels_list = sorted(characters_pixels_list0, 
        key=lambda pixels_list: get_error(pixels_list, image))

    seen = reduce(set.union, [background_pixels] + characters_pixels)
    max_uncertain_groups = 8
    uncertain_pixels = list(sorted(get_zones(image, seen, 255, 20), 
        key=len))[:max_uncertain_groups]
    debug("Uncertain groups: %d - %s" % (len(uncertain_pixels), 
        [len(x) for x in uncertain_pixels]))
    characters4_pixels_list2 = characters4_pixels_list[:maxiterations]
    candidates = build_candidates(characters4_pixels_list2, uncertain_pixels)
        
    best = histogram(candidates)
    if not best:
        debug("No word candidates")
        return                
    debug("Best words: %s" % best[-5:][::-1])    
    return best[-1][0]
        
        
def main(args):
    """Main function for megaupload captcha decoder."""
    import optparse
    usage = """usage: megaupload_captcha [OPTIONS] [IMAGE_FILE]
    
    Decode Megaupload captcha."""
    parser = optparse.OptionParser(usage)
    parser.add_option('-q', '--quiet', dest='quiet',
        action="store_true", default=False, help='Be quiet')
    parser.add_option('-d', '--disable-psyco', dest='disable_psyco',
        action="store_true", default=False, help='Be quiet')
    parser.add_option('-i', '--max-iterations', dest='max_iterations',
        default=1, metavar='INTEGER', type='int', 
        help='Maximum iterations on characters agrupations')
    options, args0 = parser.parse_args(args)
    if not args0:
        parser.print_help()
        return 1
    if options.quiet:
        global DEBUG
        DEBUG = False
    debug("Loading psyco: ", linefeed=False)
    if options.disable_psyco:
        debug("disabled")
    elif load_psyco():
        debug("ok")
    else: debug("failed")
    filename, = args0
    stream = (sys.stdin if filename == "-" else open(filename))
    captcha_image = Image.open(StringIO(stream.read()))
    captcha = decode_megaupload_captcha(captcha_image, options.max_iterations)
    if captcha:
        print captcha


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
