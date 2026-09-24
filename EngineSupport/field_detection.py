"""Conservative current-page candidates from vector rules, never automatic widgets.
Raster/scanned pages need manual placement; this module does not perform OCR.
"""
import ctypes as c
from contextlib import closing
from engine import pdfium_adapter as p
from engine.errors import require


def candidates(horizontal, vertical, occupied, crop):
    """Empty bounded cells and standalone answer lines, in PDF page coordinates."""
    def intersects(a,b): return min(a[2],b[2]) > max(a[0],b[0]) and min(a[3],b[3]) > max(a[1],b[1])
    def clear(rect):
        inside = [rect[0]+1,rect[1]+1,rect[2]-1,rect[3]-1]
        return not any(intersects(inside, box) for box in occupied)
    def within(rect): return crop[0]<=rect[0]<rect[2]<=crop[2] and crop[1]<=rect[1]<rect[3]<=crop[3]
    result=[]
    def add(rect, kind):
        if not within(rect) or not clear(rect): return
        # The smallest empty cell wins over a containing table rectangle.
        if any(intersects(rect, f['rect']) for f in result): return
        result.append({'type':kind,'rect':[round(x,2) for x in rect]})
    boxes=[]
    for i,(y,x0,x1) in enumerate(horizontal):
        for yy,xx0,xx1 in horizontal[i+1:]:
            bottom,top=sorted((y,yy)); h=top-bottom
            if not 7<=h<=72: continue
            lo,hi=max(x0,xx0),min(x1,xx1)
            xs=sorted(set(round(x,1) for x,a,b in vertical if a<=bottom+1 and b>=top-1 and lo-1<=x<=hi+1))
            for left,right in zip(xs,xs[1:]):
                w=right-left
                if not 7<=w<=360: continue
                box=[left,bottom,right,top]
                if clear(box): boxes.append(box)
    for rect in sorted(boxes,key=lambda r:(r[2]-r[0])*(r[3]-r[1])):
        w,h=rect[2]-rect[0],rect[3]-rect[1]
        checkbox=7<=w<=20 and 7<=h<=20 and .7<=w/h<=1.4
        if checkbox or w>=22: add(rect,'checkbox' if checkbox else 'text')
    for y,x0,x1 in horizontal:
        if not 35<=x1-x0<=260: continue
        # A table edge is not an independent answer line.
        if any(abs(x-x0)<2 or abs(x-x1)<2 for x,a,b in vertical if a-1<=y<=b+1): continue
        add([x0,y+1,x1,y+14],'text')
    result.sort(key=lambda f:(-f['rect'][3],f['rect'][0]))
    for i,f in enumerate(result): f['name']=f"Field {i+1}"
    return result[:200]


def detect_fields(path, page_index):
    r=p.r
    with p.document(path) as doc, closing(doc[page_index]) as page, closing(page.get_textpage()) as text:
        occupied=[]
        count=text.count_chars()
        require(count<=50000,'UNSUPPORTED_OPERATION','This page is too complex for automatic detection. Add fields manually.')
        for i in range(count):
            if text.get_text_range(i,1).strip(): occupied.append(list(text.get_charbox(i)))
        for i in range(r.FPDFPage_GetAnnotCount(page)):
            with p.annotation(page,i) as annot:
                if r.FPDFAnnot_GetSubtype(annot)==r.FPDF_ANNOT_WIDGET:
                    rect=r.FS_RECTF(); r.FPDFAnnot_GetRect(annot,rect)
                    occupied.append([rect.left,rect.bottom,rect.right,rect.top])
        horizontal=[]; vertical=[]; budget=0
        identity=(1,0,0,1,0,0)
        def transform(m,x,y):
            a,b,cc,d,e,f=m; return a*x+cc*y+e,b*x+d*y+f
        def compose(a,b):
            # Parent applied after local object matrix.
            aa,ab,ac,ad,ae,af=a; ba,bb,bc,bd,be,bf=b
            return (aa*ba+ac*bb,ab*ba+ad*bb,aa*bc+ac*bd,ab*bc+ad*bd,aa*be+ac*bf+ae,ab*be+ad*bf+af)
        def line(a,b):
            if abs(a[1]-b[1])<.6 and abs(a[0]-b[0])>=7:
                horizontal.append((round((a[1]+b[1])/2,1),min(a[0],b[0]),max(a[0],b[0])))
            elif abs(a[0]-b[0])<.6 and abs(a[1]-b[1])>=7:
                vertical.append((round((a[0]+b[0])/2,1),min(a[1],b[1]),max(a[1],b[1])))
        def visit(obj,parent,depth):
            nonlocal budget
            budget+=1
            require(budget<=30000 and depth<=12,'UNSUPPORTED_OPERATION','This page is too complex for automatic detection.')
            mat=r.FS_MATRIX(); p.native(r.FPDFPageObj_GetMatrix(obj,mat),'read object matrix')
            matrix=compose(parent,(mat.a,mat.b,mat.c,mat.d,mat.e,mat.f))
            typ=r.FPDFPageObj_GetType(obj)
            if typ==r.FPDF_PAGEOBJ_FORM:
                for i in range(r.FPDFFormObj_CountObjects(obj)): visit(r.FPDFFormObj_GetObject(obj,i),matrix,depth+1)
            elif typ==r.FPDF_PAGEOBJ_PATH:
                fill=c.c_int(); stroke=r.FPDF_BOOL()
                r.FPDFPath_GetDrawMode(obj,fill,stroke)
                if not stroke.value: return
                previous=start=None
                n=r.FPDFPath_CountSegments(obj)
                require(n<=10000,'UNSUPPORTED_OPERATION','Path is too complex for automatic detection.')
                for i in range(n):
                    segment=r.FPDFPath_GetPathSegment(obj,i); x=c.c_float(); y=c.c_float()
                    p.native(r.FPDFPathSegment_GetPoint(segment,x,y),'read rule geometry')
                    point=transform(matrix,x.value,y.value); kind=r.FPDFPathSegment_GetType(segment)
                    if kind==r.FPDF_SEGMENT_MOVETO: start=point
                    elif kind==r.FPDF_SEGMENT_LINETO and previous: line(previous,point)
                    if r.FPDFPathSegment_GetClose(segment) and start and kind==r.FPDF_SEGMENT_LINETO: line(point,start)
                    previous=point
        for i in range(r.FPDFPage_CountObjects(page)): visit(r.FPDFPage_GetObject(page,i),identity,0)
        def merged(lines):
            groups={}
            for axis,a,b in lines: groups.setdefault(axis,[]).append((a,b))
            out=[]
            for axis,parts in groups.items():
                for a,b in sorted(parts):
                    if out and out[-1][0]==axis and a<=out[-1][2]+1: out[-1]=(axis,out[-1][1],max(b,out[-1][2]))
                    else: out.append((axis,a,b))
            return out
        h,v=merged(horizontal),merged(vertical)
        require(len(h)<=300 and len(v)<=300,'UNSUPPORTED_OPERATION','This page has too many rules to detect safely.')
        return {'fields':candidates(h,v,occupied,list(page.get_cropbox())),
                'limitation':'Suggestions use empty vector boxes and lines. Scans and some artwork require manual placement.'}
