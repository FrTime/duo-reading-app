import os
OUT=os.path.dirname(os.path.abspath(__file__))+"/svg"; os.makedirs(OUT,exist_ok=True)

def svg(body, defs=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>{defs}</defs>{body}</svg>'

def bg(v, light, dark):
    if v=="tinted": return '<rect width="1024" height="1024" fill="#000"/>'
    a,b = light if v=="light" else dark
    return f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>', '<rect width="1024" height="1024" fill="url(#bg)"/>'

def B(v, light, dark):
    r=bg(v,light,dark)
    return ("",r) if isinstance(r,str) else r

# ---------- 1. Open Book (pages = Duo halves) ----------
def open_book(v, moon=False):
    if moon:
        d,b=B(v,("#24305E","#0E1430"),("#141A36","#05070F"))
    else:
        d,b=B(v,("#8A5230","#4A2715"),("#3A2214","#140A05"))
    t=v=="tinted"
    page = "#FFFFFF" if t else ("#F7EEDB" if v=="light" else "#E9DCC0")
    pageShade = "#9A9A9A" if t else ("#D8C7A3" if v=="light" else "#B8A57F")
    cover = "#5A5A5A" if t else ("#7C1F2A" if not moon else "#2F3F80")
    line = "#7A7A7A" if t else "#B9A47E"
    ribbon = "#C8C8C8" if t else ("#C9343F" if not moon else "#E8B84A")
    d+=f'''<linearGradient id="pl" x1="0" x2="1"><stop offset="0" stop-color="{page}"/><stop offset=".82" stop-color="{page}"/><stop offset="1" stop-color="{pageShade}"/></linearGradient>
<linearGradient id="pr" x1="1" x2="0"><stop offset="0" stop-color="{page}"/><stop offset=".82" stop-color="{page}"/><stop offset="1" stop-color="{pageShade}"/></linearGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity=".35"/></filter>'''
    yo = 60 if moon else 0
    def P(dy): return dy+yo
    covers=f'<path d="M512 {P(380)} C 410 {P(330)} 280 {P(318)} 168 {P(350)} L 168 {P(752)} C 290 {P(722)} 410 {P(734)} 512 {P(790)} C 614 {P(734)} 734 {P(722)} 856 {P(752)} L 856 {P(350)} C 744 {P(318)} 614 {P(330)} 512 {P(380)} Z" fill="{cover}"/>'
    left=f'<path d="M512 {P(372)} C 420 {P(318)} 300 {P(300)} 196 {P(322)} L 196 {P(722)} C 300 {P(700)} 420 {P(712)} 512 {P(768)} Z" fill="url(#pl)"/>'
    right=f'<path d="M512 {P(372)} C 604 {P(318)} 724 {P(300)} 828 {P(322)} L 828 {P(722)} C 724 {P(700)} 604 {P(712)} 512 {P(768)} Z" fill="url(#pr)"/>'
    lines=""
    for i in range(6):
        y=P(392+i*52)
        lines+=f'<path d="M240 {y} C 320 {y-14} 400 {y-8} 466 {y+14}" stroke="{line}" stroke-width="12" stroke-linecap="round" fill="none"/>'
        lines+=(f'<path d="M558 {y+14} C 624 {y-8} 704 {y-14} 784 {y}" stroke' if i!=5 else f'<path d="M558 {y+14} C 600 {y-2} 640 {y-8} 680 {y-8}" stroke')+f'="{line}" stroke-width="12" stroke-linecap="round" fill="none"/>'
    rib=f'<path d="M496 {P(700)} L 528 {P(700)} L 528 {P(900)} L 512 {P(876)} L 496 {P(900)} Z" fill="{ribbon}"/>'
    extra=""
    if moon:
        mc = "#FFFFFF" if t else "#F6D77A"
        extra=f'<path d="M560 150 a 120 120 0 1 0 140 170 a 96 96 0 1 1 -140 -170 Z" fill="{mc}"/>'
        for x,y,r in [(330,190,10),(410,120,7),(770,180,8),(250,290,6),(800,300,6)]:
            extra+=f'<circle cx="{x}" cy="{y}" r="{r}" fill="{mc}" opacity=".85"/>'
    return svg(b+extra+f'<g filter="url(#sh)">{covers}{left}{right}</g>'+lines+rib, d)

# ---------- 2. Wooden shelf of spines ----------
def shelf(v):
    t=v=="tinted"
    d,b=B(v,("#B9773F","#7A4422"),("#3B2416","#1A0E07"))
    grain="" if t else "".join(f'<path d="M0 {y} C 300 {y+20} 700 {y-25} 1024 {y+8}" stroke="#000" stroke-opacity=".07" stroke-width="6" fill="none"/>' for y in range(60,1000,70))
    plank = "#444" if t else ("#5A3218" if v=="light" else "#2A170B")
    plankTop = "#777" if t else ("#8E5A32" if v=="light" else "#4C2D17")
    books=[(212,110,420,"#2E5E4E"),(330,96,470,"#B8402E"),(434,124,390,"#E0B252"),(566,104,450,"#28457A")]
    if v=="dark": books=[(x,w,h,c) for x,w,h,c in books]
    s=""
    for i,(x,w,h,c) in enumerate(books):
        if t: c=["#BDBDBD","#FFFFFF","#8E8E8E","#D8D8D8"][i]
        top=790-h
        band = "#000" if t else "#F2D27C"
        s+=f'<rect x="{x}" y="{top}" width="{w-10}" height="{h}" rx="14" fill="{c}"/>'
        s+=f'<rect x="{x}" y="{top+40}" width="{w-10}" height="14" fill="{band}" opacity=".9"/>'
        s+=f'<rect x="{x}" y="{790-70}" width="{w-10}" height="14" fill="{band}" opacity=".9"/>'
        s+=f'<rect x="{x+(w-10)/2-22}" y="{top+100}" width="44" height="{min(150,h-220)}" rx="8" fill="{band}" opacity=".35"/>'
    # leaning book
    lc = "#9E9E9E" if t else "#7B2E5E"
    s+=f'<g transform="rotate(16 690 790)"><rect x="690" y="{790-430}" width="104" height="430" rx="14" fill="{lc}"/><rect x="690" y="{790-390}" width="104" height="14" fill="{"#000" if t else "#F2D27C"}" opacity=".9"/><rect x="690" y="{790-84}" width="104" height="14" fill="{"#000" if t else "#F2D27C"}" opacity=".9"/></g>'
    p=f'<rect x="120" y="790" width="784" height="40" rx="6" fill="{plankTop}"/><rect x="120" y="826" width="784" height="44" rx="6" fill="{plank}"/>'
    sh='<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#000" flood-opacity=".35"/></filter>'
    return svg(b+grain+f'<g transform="translate(512 560) scale(1.16) translate(-512 -560)"><g filter="url(#sh)">{s}{p}</g></g>', d+sh)

# ---------- 3. Hardcover with ribbon ----------
def hardcover(v):
    t=v=="tinted"
    d,b=B(v,("#F3E3C3","#E1C48F"),("#1E2B2A","#0B1110"))
    cov = "#BFBFBF" if t else "#1F5E57"
    covD = "#7A7A7A" if t else "#123F3A"
    pages = "#FFFFFF" if t else "#F8F1E0"
    gold = "#FFFFFF" if t else "#E9C46A"
    rib = "#E5E5E5" if t else "#C8423B"
    d+=f'<linearGradient id="cv" x1="0" x2="1"><stop offset="0" stop-color="{covD}"/><stop offset=".12" stop-color="{cov}"/><stop offset="1" stop-color="{cov}"/></linearGradient><filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="10" dy="26" stdDeviation="26" flood-color="#000" flood-opacity=".35"/></filter>'
    body=f'''<g filter="url(#sh)">
<rect x="300" y="196" width="470" height="620" rx="26" fill="{pages}"/>
<path d="M300 210 h 446 v 600 h -446 z" fill="{pages}"/>
{''.join(f'<line x1="760" y1="{y}" x2="760" y2="{y+560}" stroke="{"#999" if t else "#D9C9A6"}" stroke-width="4"/>'[0:0] for y in [0])}
<rect x="262" y="180" width="480" height="640" rx="30" fill="url(#cv)"/>
</g>
<rect x="742" y="214" width="26" height="584" fill="{pages}"/>
<line x1="752" y1="222" x2="752" y2="790" stroke="{"#9A9A9A" if t else "#D3C29C"}" stroke-width="3"/>
<line x1="760" y1="222" x2="760" y2="790" stroke="{"#9A9A9A" if t else "#D3C29C"}" stroke-width="3"/>
<rect x="262" y="180" width="62" height="640" rx="30" fill="{covD}"/>
<rect x="318" y="180" width="10" height="640" fill="#000" opacity=".18"/>
<rect x="372" y="250" width="310" height="500" rx="14" fill="none" stroke="{gold}" stroke-width="10"/>
<rect x="430" y="380" width="194" height="16" rx="8" fill="{gold}"/>
<rect x="460" y="420" width="134" height="12" rx="6" fill="{gold}" opacity=".8"/>
<path d="M527 470 l 22 44 48 7 -35 34 8 48 -43 -23 -43 23 8 -48 -35 -34 48 -7 z" fill="{gold}"/>
<path d="M600 800 L 646 800 L 646 930 L 623 902 L 600 930 Z" fill="{rib}"/>'''
    return svg(b+body,d)

# ---------- 4. Unfolded Duo as a book ----------
def duo(v):
    t=v=="tinted"
    d,b=B(v,("#4E6CC9","#22306E"),("#18204A","#070A1C"))
    frame = "#5E5E5E" if t else "#1A1D2B"
    screen = "#FFFFFF" if t else "#F7EEDB"
    line = "#8A8A8A" if t else "#B9A47E"
    rib = "#D0D0D0" if t else "#E3544A"
    d+='<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#000" flood-opacity=".4"/></filter>'
    # two panels angled (trapezoids) meeting at hinge x=512
    L=f'<path d="M500 250 L 196 300 Q 168 305 168 334 L 168 714 Q 168 743 196 746 L 500 790 Z" fill="{frame}"/>'
    R=f'<path d="M524 250 L 828 300 Q 856 305 856 334 L 856 714 Q 856 743 828 746 L 524 790 Z" fill="{frame}"/>'
    hinge=f'<rect x="496" y="244" width="32" height="552" rx="14" fill="{"#888" if t else "#3A3F55"}"/>'
    Ls=f'<path d="M488 284 L 210 328 L 210 718 L 488 756 Z" fill="{screen}"/>'
    Rs=f'<path d="M536 284 L 814 328 L 814 718 L 536 756 Z" fill="{screen}"/>'
    lines=""
    for i in range(7):
        f=i/6
        yl1=372+f*312; yl2=yl1-26+f*10
        lines+=f'<line x1="250" y1="{yl1:.0f}" x2="452" y2="{yl1-0.11*202+ (6):.0f}" stroke="{line}" stroke-width="11" stroke-linecap="round"/>'
        xe = 774 if i!=6 else 680
        lines+=f'<line x1="572" y1="{yl1-0.11*202+6:.0f}" x2="{xe}" y2="{yl1 - (0.11*202)*(1-(xe-572)/202) +6 - (6 if xe==774 else 0):.0f}" stroke="{line}" stroke-width="11" stroke-linecap="round"/>'
    rib_=f'<path d="M740 316 L 780 322 L 780 470 L 760 448 L 740 466 Z" fill="{rib}"/>'
    return svg(b+f'<g filter="url(#sh)">{L}{R}{hinge}</g>'+Ls+Rs+lines+rib_, d)

# ---------- 5. Bookmark monogram ----------
def bookmark(v):
    t=v=="tinted"
    d,b=B(v,("#F6E7CF","#EBCFA2"),("#2A1A12","#120A06"))
    rib = "#FFFFFF" if t else "#C8423B"
    ribD = "#9A9A9A" if t else "#9E2C27"
    stitch = "#000" if t else "#F6D9A8"
    page = "#B5B5B5" if t else ("#FFFDF7" if v=="light" else "#E8DAC0")
    d+=f'<linearGradient id="rb" x1="0" x2="1"><stop offset="0" stop-color="{ribD}"/><stop offset=".25" stop-color="{rib}"/><stop offset=".75" stop-color="{rib}"/><stop offset="1" stop-color="{ribD}"/></linearGradient><filter id="sh" x="-30%" y="-20%" width="160%" height="160%"><feDropShadow dx="0" dy="20" stdDeviation="24" flood-color="#000" flood-opacity=".3"/></filter>'
    pagesG=f'<path d="M196 300 Q 512 230 828 300 L 828 360 Q 512 290 196 360 Z" fill="{page}" opacity=".95"/><path d="M196 340 Q 512 270 828 340 L 828 372 Q 512 302 196 372 Z" fill="{page}" opacity=".55"/>' if False else ''
    cov2 = "#6A6A6A" if t else ("#3B2A20" if v=="light" else "#5A3E2C")
    top=f'<g filter="url(#sh)"><rect x="176" y="196" width="672" height="132" rx="34" fill="{cov2}"/><rect x="204" y="214" width="616" height="96" rx="20" fill="{page}"/></g>'+''.join(f'<line x1="224" y1="{y}" x2="800" y2="{y}" stroke="{"#7A7A7A" if t else "#D7C7A8"}" stroke-width="4"/>' for y in range(232,300,14))
    r=f'<path d="M402 300 L 622 300 L 622 860 L 512 760 L 402 860 Z" fill="url(#rb)"/>'
    st=f'<path d="M428 300 L 428 800 M 596 300 L 596 800" stroke="{stitch}" stroke-width="7" stroke-dasharray="22 16" stroke-linecap="round" opacity=".8"/>'
    return svg(b+f'<g filter="url(#sh)">{r}</g>'+st+top, d)

concepts={"open-book":lambda v:open_book(v),"night-reader":lambda v:open_book(v,moon=True),"bookshelf":shelf,"hardcover":hardcover,"duo-book":duo,"bookmark":bookmark}
for n,f in concepts.items():
    for v in ["light","dark","tinted"]:
        open(f"{OUT}/{n}-{v}.svg","w").write(f(v))
print("ok")

import re
def duo_glyph(v):
    s=duo(v)
    inner=s.split('</defs>',1)[1].rsplit('</svg>',1)[0]
    inner=re.sub(r'<rect width="1024" height="1024"[^>]*/>','',inner,count=1)
    inner=inner.replace('filter="url(#sh)"','')
    return inner
def shelf2(v, mode):
    t=v=="tinted"
    d,b=B(v,("#B9773F","#7A4422"),("#3B2416","#1A0E07"))
    grain="" if t else "".join(f'<path d="M0 {y} C 300 {y+20} 700 {y-25} 1024 {y+8}" stroke="#000" stroke-opacity=".07" stroke-width="6" fill="none"/>' for y in range(60,1000,70))
    plank = "#444" if t else ("#5A3218" if v=="light" else "#2A170B")
    plankTop = "#777" if t else ("#8E5A32" if v=="light" else "#4C2D17")
    band = "#000" if t else "#F2D27C"
    books=[(212,110,420,"#2E5E4E"),(330,96,470,"#B8402E"),(434,124,390,"#E0B252"),(566,104,450,"#28457A")]
    dx = -36 if mode=="a" else 0
    s=""
    for i,(x,w,h,c) in enumerate(books):
        x+=dx
        if t: c=["#BDBDBD","#FFFFFF","#8E8E8E","#D8D8D8"][i]
        top=790-h
        s+=f'<rect x="{x}" y="{top}" width="{w-10}" height="{h}" rx="14" fill="{c}"/><rect x="{x}" y="{top+40}" width="{w-10}" height="14" fill="{band}" opacity=".9"/><rect x="{x}" y="{790-70}" width="{w-10}" height="14" fill="{band}" opacity=".9"/>'
        if mode=="c" and i==3:
            # tiny duo emblem on spine instead of label
            cx=x+(w-10)/2; y0=top+120
            s+=f'<g transform="translate({cx} {y0}) scale(.11) translate(-512 -244)">{duo_glyph(v)}</g>'
        else:
            s+=f'<rect x="{x+(w-10)/2-22}" y="{top+100}" width="44" height="{min(150,h-220)}" rx="8" fill="{band}" opacity=".35"/>'
    lc = "#9E9E9E" if t else "#7B2E5E"
    if mode!="a":
        s+=f'<g transform="rotate(16 690 790)"><rect x="690" y="360" width="104" height="430" rx="14" fill="{lc}"/><rect x="690" y="400" width="104" height="14" fill="{band}" opacity=".9"/><rect x="690" y="706" width="104" height="14" fill="{band}" opacity=".9"/></g>'
    p=f'<rect x="120" y="790" width="784" height="40" rx="6" fill="{plankTop}"/><rect x="120" y="826" width="784" height="44" rx="6" fill="{plank}"/>'
    fg=""
    if mode=="a":   # open Duo standing at the end of the row
        sc=.36; cx=780
        fg=f'<g filter="url(#sh)" transform="translate({cx} 790) scale({sc}) translate(-512 -781)">{duo_glyph(v)}</g>'
    if mode=="b":   # small Duo propped in front of the books
        sc=.30; cx=420
        fg=f'<g filter="url(#sh2)" transform="translate({cx} 796) scale({sc}) translate(-512 -796)">{duo_glyph(v)}</g>'
    sh='<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#000" flood-opacity=".35"/></filter><filter id="sh2" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity=".5"/></filter>'
    return svg(b+grain+f'<g transform="translate(512 560) scale(1.16) translate(-512 -560)"><g filter="url(#sh)">{s}{p}</g>{fg}</g>', d+sh)
os.makedirs(OUT+"5",exist_ok=True)
for m in "abc":
    for v in ["light","dark","tinted"]:
        open(f"{OUT}5/bookshelf-{m}-{v}.svg","w").write(shelf2(v,m))

def duo(v):
    t=v=="tinted"
    d,b=B(v,("#4E6CC9","#22306E"),("#18204A","#070A1C"))
    frame = "#5E5E5E" if t else "#1A1D2B"
    screen = "#FFFFFF" if t else "#F7EEDB"
    crease = "#9A9A9A" if t else "#D9C9A6"
    line = "#8A8A8A" if t else "#B9A47E"
    rib = "#D0D0D0" if t else "#E3544A"
    d+=f'<filter id="sh" x="-20%" y="-20%" width="140%" height="160%"><feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#000" flood-opacity=".4"/></filter><linearGradient id="cr" x1="0" x2="1"><stop offset="0" stop-color="{screen}"/><stop offset=".5" stop-color="{crease}"/><stop offset="1" stop-color="{screen}"/></linearGradient>'
    body=f'<path d="M512 298 L 204 262 Q 176 259 176 288 L 176 752 Q 176 781 204 778 L 512 742 L 820 778 Q 848 781 848 752 L 848 288 Q 848 259 820 262 Z" fill="{frame}"/>'
    scr=f'<path d="M512 315 L 200 280 Q 194 279 194 286 L 194 754 Q 194 761 200 760 L 512 725 L 824 760 Q 830 761 830 754 L 830 286 Q 830 279 824 280 Z" fill="{screen}"/>'
    cr=f'<rect x="496" y="315" width="32" height="410" fill="url(#cr)" opacity=".7"/>'
    def yat(x,f):  # y on left/right half at fraction f between top and bottom edges
        k=abs(x-512)/318
        top=315-35*k; bot=725+35*k
        return top+(bot-top)*f
    lines=""
    for i in range(7):
        f=0.17+i*0.11
        for (x1,x2) in [(240,468),(556,784 if i!=6 else 690)]:
            lines+=f'<line x1="{x1}" y1="{yat(x1,f):.0f}" x2="{x2}" y2="{yat(x2,f):.0f}" stroke="{line}" stroke-width="11" stroke-linecap="round"/>'
    rib_=f'<path d="M742 {yat(742,0)+4:.0f} L 778 {yat(778,0)+4:.0f} L 778 {yat(778,0)+140:.0f} L 760 {yat(778,0)+120:.0f} L 742 {yat(742,0)+140:.0f} Z" fill="{rib}"/>'
    cam=f'<circle cx="666" cy="{yat(666,0)+18:.0f}" r="9" fill="{frame}"/>'
    return svg(b+f'<g filter="url(#sh)">{body}</g>'+scr+cr+lines+rib_, d)

for v in ["light","dark","tinted"]:
    open(f"{OUT}/duo-book-{v}.svg","w").write(duo(v))
    open(f"{OUT}5/bookshelf-a-{v}.svg","w").write(shelf2(v,"a"))
