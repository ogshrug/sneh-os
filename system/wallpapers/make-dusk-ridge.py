"""dusk ridge - Sneh's default wallpaper: layered ridges, pines and a low sun in
the dusk palette. Drawn from scratch with Pillow (no source art), so it ships
with Sneh under the same MIT licence.

    python3 make-dusk-ridge.py OUT.jpg [SEED]      (the shipped file: seed 11)
"""
import math, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

W, H = 3840, 2160
random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 11)
out = sys.argv[1]

def hx(s): return tuple(int(s[i:i+2], 16) for i in (0, 2, 4))
def mix(a, b, t): return tuple(round(a[i] + (b[i]-a[i])*t) for i in range(3))

NIGHT, DEEP, VIOLET, LAV, ROSE, PEACH, CREAM = map(hx, ['080a18', '121634', '2c2860', '6d5fae', 'c9879c', 'efb2a4', 'fbe3d2'])

# --- sky: multi-stop vertical gradient ---------------------------------------
stops = [(0.00, NIGHT), (0.18, DEEP), (0.34, VIOLET), (0.46, LAV), (0.55, ROSE), (0.62, PEACH), (0.68, CREAM)]
sky = Image.new('RGB', (1, H))
for y in range(H):
    t = y / H
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            u = (t - t0) / (t1 - t0); u = u*u*(3-2*u)
            sky.putpixel((0, y), mix(c0, c1, max(0, min(1, u)))); break
    else:
        sky.putpixel((0, y), CREAM)
img = sky.resize((W, H))

# sun glow + disc
SX, SY, SR = int(W*0.66), int(H*0.585), int(H*0.075)
glow = Image.new('L', (W, H), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse((SX-SR*4, SY-SR*3, SX+SR*4, SY+SR*3), fill=120)
glow = glow.filter(ImageFilter.GaussianBlur(SR*1.6))
img = Image.composite(Image.new('RGB', (W, H), CREAM), img, glow)
disc = Image.new('L', (W, H), 0)
ImageDraw.Draw(disc).ellipse((SX-SR, SY-SR, SX+SR, SY+SR), fill=255)
img = Image.composite(Image.new('RGB', (W, H), (255, 236, 220)), img, disc.filter(ImageFilter.GaussianBlur(3)))

# stars in the upper sky
d = ImageDraw.Draw(img)
for _ in range(420):
    x, y = random.randrange(W), int(random.random()**1.8 * H*0.38)
    b = random.randint(120, 235); r = random.choice([1, 1, 1, 2, 2, 3])
    d.ellipse((x, y, x+r, y+r), fill=mix(img.getpixel((x, y)), (255, 250, 245), b/255))

# long thin clouds lit from below
clouds = Image.new('RGBA', (W, H), (0, 0, 0, 0))
cd = ImageDraw.Draw(clouds)
for _ in range(46):
    y = random.uniform(0.26, 0.56) * H
    x = random.uniform(-0.2, 1.0) * W
    w = random.uniform(0.15, 0.55) * W
    h = random.uniform(6, 26)
    t = (y/H - 0.26) / 0.30
    col = mix(mix(LAV, ROSE, 0.4), PEACH, t)
    cd.ellipse((x, y, x+w, y+h), fill=col + (random.randint(60, 150),))
clouds = clouds.filter(ImageFilter.GaussianBlur(9))
img = Image.alpha_composite(img.convert('RGBA'), clouds).convert('RGB')

# --- ridges -------------------------------------------------------------------
def ridge(base, amp, rough, seg=1):
    n = 2**10 + 1
    pts = [0.0]*n
    pts[0], pts[-1] = random.uniform(-1, 1), random.uniform(-1, 1)
    step, a = n-1, 1.0
    while step > 1:
        half = step//2
        for i in range(half, n-1, step):
            pts[i] = (pts[i-half] + pts[i+half])/2 + random.uniform(-a, a)
        a *= rough; step = half
    return [(i*W/(n-1), base - pts[i]*amp) for i in range(n)]

def tree(dr, x, ground, h, col):
    w = h*0.36
    dr.rectangle((x-h*0.018, ground-h*0.12, x+h*0.018, ground+4), fill=col)
    tiers = 6
    for k in range(tiers):
        top = ground - h + k*h*0.13
        bot = top + h*0.30
        ww = w*(0.30 + 0.70*(k+1)/tiers)
        dr.polygon([(x, top), (x-ww/2, bot), (x-ww*0.18, bot-h*0.03), (x+ww*0.18, bot-h*0.03), (x+ww/2, bot)], fill=col)

layers = [  # base y, amplitude, roughness, colour, haze, trees(min,max height, density)
    (0.56, 0.22, 0.47, mix(LAV, ROSE, 0.45), 0.60, None),
    (0.64, 0.16, 0.50, mix(VIOLET, LAV, 0.65), 0.45, None),
    (0.72, 0.10, 0.55, mix(VIOLET, DEEP, 0.10), 0.28, (0.025, 0.045, 0.30)),
    (0.80, 0.06, 0.58, mix(DEEP, VIOLET, 0.30), 0.12, (0.045, 0.085, 0.28)),
    (0.90, 0.05, 0.60, mix(NIGHT, DEEP, 0.55), 0.0, (0.09, 0.19, 0.26)),
    (1.00, 0.06, 0.60, NIGHT, 0.0, (0.22, 0.42, 0.14)),
]
for base, amp, rough, col, haze, trees in layers:
    L = Image.new('L', (W, H), 0)
    dr = ImageDraw.Draw(L)
    pts = ridge(base*H, amp*H, rough)
    dr.polygon(pts + [(W, H), (0, H)], fill=255)
    if trees:
        lo, hi, gap = trees
        x = random.uniform(0, gap*H*0.3)
        while x < W:
            if lo >= 0.2 and 0.30*W < x < 0.80*W: x += gap*H*0.4; continue
            i = min(len(pts)-1, int(x/W*(len(pts)-1)))
            tree(dr, x, pts[i][1] + 6, random.uniform(lo, hi)*H, 255)
            x += random.uniform(0.25, 1.0) * gap * H * (0.35 if random.random() < 0.6 else 1.2)
    # the layer: its colour, fading towards the sky colour at the top of each ridge (haze)
    fill = Image.new('RGB', (W, H), col)
    if haze:
        top = Image.new('RGB', (W, H), mix(col, PEACH, haze*0.5))
        ramp = Image.linear_gradient('L').resize((W, H))
        fill = Image.composite(fill, top, ramp)
    img = Image.composite(fill, img, L.filter(ImageFilter.GaussianBlur(1.2)))
    # mist band at the foot of each distant ridge
    if haze:
        m = Image.new('L', (W, H), 0)
        ImageDraw.Draw(m).rectangle((0, base*H + amp*H*0.2, W, base*H + amp*H*1.4), fill=int(80*haze))
        img = Image.composite(Image.new('RGB', (W, H), mix(ROSE, PEACH, 0.5)), img, m.filter(ImageFilter.GaussianBlur(40)))

# fine grain
noise = Image.effect_noise((W, H), 10).convert('RGB')
img = Image.blend(img, ImageChops.overlay(img, noise), 0.08)
img.resize((2560, 1440), Image.LANCZOS).save(out, quality=90, optimize=True, progressive=True)
print('ok', out)
