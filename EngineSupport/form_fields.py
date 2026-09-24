"""Private app form authoring: reviewed text/checkbox fields, never automatic edits."""
import base64
import json
import math
from copy import deepcopy
from engine.errors import require
from engine.session import equivalent
from engine.runtime import staging
from engine import policy


def add_fields(engine, ref, fields):
    session = engine._get(ref)
    policy.guard(session.policy)
    require(isinstance(fields, list) and 0 < len(fields) <= 200, 'INVALID_ARGUMENT', 'Choose between 1 and 200 fields.')
    structure, _ = engine._qpdf.inspect(session.path)
    names = {f['name'] for f in session.raw['fields']}
    specs = []
    for spec in fields:
        require(isinstance(spec, dict), 'INVALID_ARGUMENT', 'Invalid field specification.')
        name, kind, rect = spec.get('name'), spec.get('type'), spec.get('rect')
        require(isinstance(name, str) and name.strip() and len(name) <= 200 and '\0' not in name and '.' not in name and name not in names,
                'INVALID_ARGUMENT', 'Field names must be unique, nonempty, and contain no dots.')
        names.add(name)
        require(kind in ('text', 'checkbox'), 'UNSUPPORTED_OPERATION', 'Only text fields and checkboxes can be created.')
        page = engine._page(session, spec.get('page_id'))
        require(isinstance(rect, list) and len(rect) == 4 and all(type(v) in (int, float) and math.isfinite(v) for v in rect),
                'INVALID_ARGUMENT', 'Invalid field bounds.')
        crop = session.raw['pages'][page]['crop_box']
        require(crop[0] <= rect[0] < rect[2] <= crop[2] and crop[1] <= rect[1] < rect[3] <= crop[3]
                and rect[2]-rect[0] >= 4 and rect[3]-rect[1] >= 4, 'INVALID_ARGUMENT', 'Fields must fit within the page.')
        specs.append(dict(name=name, type=kind, rect=rect, page=page))
    objects = {}
    # QPDF includes dangling references in maxobjectid; never reuse their IDs.
    metadata, _ = engine._qpdf.run(['--json', '--json-key=qpdf', session.path], inspection=True)
    next_id = json.loads(metadata)['qpdf'][0]['maxobjectid'] + 1
    def obj(value=None, stream=None):
        nonlocal next_id
        ref = f'{next_id} 0 R'; next_id += 1
        objects['obj:' + ref] = {'value': value} if stream is None else {'stream': stream}
        return ref
    font_name = '/ZPDFFont' + str(next_id)
    font = obj({'/Type': '/Font', '/Subtype': '/Type1', '/BaseFont': '/Helvetica', '/Encoding': '/WinAnsiEncoding'})
    def appearance(width, height, content):
        return obj(stream={'dict': {'/Type': '/XObject', '/Subtype': '/Form', '/FormType': 1,
                                   '/BBox': [0, 0, width, height], '/Resources': {'/Font': {font_name: font}}},
                           'data': base64.b64encode(content.encode('ascii')).decode('ascii')})
    acro, _ = structure.catalog()
    roots = list(structure.resolve(acro.get('/Fields', [])))
    changed_pages = {}
    for spec in specs:
        page_ref = structure.pages[spec['page']]['object']
        if page_ref not in changed_pages:
            page = deepcopy(structure.resolve(page_ref))
            page['/Annots'] = list(structure.resolve(page.get('/Annots', [])))
            changed_pages[page_ref] = page
        x0,y0,x1,y1 = spec['rect']; w,h = x1-x0,y1-y0
        node = {'/Type': '/Annot', '/Subtype': '/Widget', '/FT': '/Tx' if spec['type']=='text' else '/Btn',
                '/T': 'u:'+spec['name'], '/TU': 'u:'+spec['name'], '/Rect': spec['rect'], '/P': page_ref,
                '/F': 4, '/Ff': 0, '/Border': [0,0,0], '/DA': 'u:'+font_name+' 10 Tf 0 g'}
        off = appearance(w,h,'q Q')
        if spec['type']=='text':
            node.update({'/V': 'u:', '/DV': 'u:', '/AP': {'/N': off}})
        else:
            on = appearance(w,h,f'q 0 G 1.2 w 1 1 m {w-1} {h-1} l 1 {h-1} m {w-1} 1 l S Q')
            node.update({'/V': '/Off', '/AS': '/Off', '/AP': {'/N': {'/Off': off, '/Yes': on}}})
        field_ref = obj(node); roots.append(field_ref)
        changed_pages[page_ref]['/Annots'].append(field_ref)
    for page_ref, page in changed_pages.items(): objects['obj:'+page_ref] = {'value': page}
    root_ref = structure.objects['trailer']['value']['/Root']
    catalog = deepcopy(structure.resolve(root_ref))
    acro_new = deepcopy(acro); acro_new['/Fields'] = roots
    resources = deepcopy(structure.resolve(acro_new.get('/DR', {})))
    fonts = deepcopy(structure.resolve(resources.get('/Font', {}))); fonts[font_name] = font
    resources['/Font'] = fonts; acro_new['/DR'] = resources
    acro_ref = catalog.get('/AcroForm')
    if isinstance(acro_ref, str): objects['obj:'+acro_ref] = {'value': acro_new}
    else:
        catalog['/AcroForm'] = acro_new
        objects['obj:'+root_ref] = {'value': catalog}
    with staging(session.storage.name) as candidate:
        patch = candidate.with_suffix('.json')
        try:
            patch.write_text(json.dumps({'qpdf': [{'jsonversion': 2}, objects]}))
            # Decode/re-encode Flate streams on a private candidate. Some IRS PDFs
            # have trailing encoded bytes. The resulting file must still pass
            # strict QPDF checks and preserve the complete semantic inventory.
            _, diagnostics = engine._qpdf.run([session.path, '--update-from-json='+str(patch),
                                               '--recompress-flate', candidate], inspection=True)
            actual, verdict = engine._load(candidate, strict=True)
            policy.guard(verdict)
            added_names = {s['name'] for s in specs}
            prior = deepcopy(actual)
            prior['fields'] = [f for f in actual['fields'] if f['name'] not in added_names]
            equivalent(session.raw, prior)
            new = [f for f in actual['fields'] if f['name'] in added_names]
            require(len(new)==len(specs), 'VALIDATION_FAILED', 'Created fields were not retained.')
            check_structure, _ = engine._qpdf.inspect(candidate)
            for spec in specs:
                field = next(f for f in new if f['name']==spec['name'])
                require(field['type']==(6 if spec['type']=='text' else 2) and field['flags']==0 and len(field['widgets'])==1,
                        'VALIDATION_FAILED', 'Created field is not editable.')
                widget = field['widgets'][0]
                require(widget['page']==spec['page'], 'VALIDATION_FAILED', 'Created field moved pages.')
                page = check_structure.resolve(check_structure.pages[widget['page']]['object'])
                node = check_structure.resolve(check_structure.resolve(page['/Annots'])[widget['index']])
                require(node['/Rect']==spec['rect'], 'VALIDATION_FAILED', 'Created field bounds changed.')
            result = engine._publish(session, candidate, actual)
            result["diagnostics"].extend(diagnostics)
            return result
        finally:
            patch.unlink(missing_ok=True)
