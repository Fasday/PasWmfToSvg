"""Сверка PasWmfToSvg с рисованием Windows, вторая половина: SVG рисует Edge или Chrome, сравнение с картинкой GDI.

Использование:
  python Tools/edge_compare.py --check <папка MfSvgCheck --out> [--old <папка>] [--worst N] [--port N]

- <папка MfSvgCheck>: <имя>.svg (PasWmfToSvg), <имя>.gdi (картинка GDI), manifest.json; --old: <имя>.svg другого
  преобразователя (если есть) - для сравнения.
- Браузер без окна рисует SVG как картинку <img> на холсте размера картинки GDI (SVG из --old - растянут), доля
  «несовпавших» пикселей (разница канала > 96) от закрашенных в GDI (разница с белым > 40), лучший сдвиг ±1 пиксель.
- Итог - <папка MfSvgCheck>/report.json; худшие - worst_NN_<имя>.png: GDI | SVG | разница (красное - не совпало) |
  SVG из --old.
"""
import argparse
import base64
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import Browser  # noqa: E402

JS = r"""
window.emf = {
  bad: 96, inkLevel: 40,
  load: function (svgB64, w, h) {
    return new Promise(function (ok, fail) {
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas'); c.width = w; c.height = h;
        var g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, w, h); g.drawImage(img, 0, 0, w, h);
        ok(g.getImageData(0, 0, w, h).data);
      };
      img.onerror = function () { fail('svg'); };
      img.src = 'data:image/svg+xml;base64,' + svgB64;
    });
  },
  gdi: function (b64, w, h) {
    var s = atob(b64), n = w * h, d = new Uint8ClampedArray(n * 4);
    for (var i = 0; i < n; i++) { d[i*4] = s.charCodeAt(i*4+2); d[i*4+1] = s.charCodeAt(i*4+1); d[i*4+2] = s.charCodeAt(i*4); d[i*4+3] = 255; }
    return d;
  },
  diff: function (a, b, i, j) {
    return Math.max(Math.abs(a[i] - b[j]), Math.abs(a[i+1] - b[j+1]), Math.abs(a[i+2] - b[j+2]));
  },
  white: function (a, i) { return Math.max(255 - a[i], 255 - a[i+1], 255 - a[i+2]); },
  score: function (a, b, w, h) {
    var best = null;
    for (var sy = -1; sy <= 1; sy++) for (var sx = -1; sx <= 1; sx++) {
      var bad = 0, ink = 0;
      for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) {
        var i = (y * w + x) * 4, bx = x + sx, by = y + sy, d;
        if (this.white(a, i) > this.inkLevel) ink++;
        if (bx < 0 || by < 0 || bx >= w || by >= h) d = this.white(a, i);
        else d = this.diff(a, b, i, (by * w + bx) * 4);
        if (d > this.bad) bad++;
      }
      var v = bad / Math.max(ink, 1);
      if (best === null || v < best.v - 1e-9) best = {v: v, ink: ink, sx: sx, sy: sy};
    }
    return best;
  },
  run: async function (gdiB64, w, h, newB64, oldB64) {
    var a = this.gdi(gdiB64, w, h), r = {};
    try { r.new = this.score(a, await this.load(newB64, w, h), w, h); } catch (e) { r.newError = String(e); }
    if (oldB64) { try { r.old = this.score(a, await this.load(oldB64, w, h), w, h); } catch (e) { r.oldError = String(e); } }
    return r;
  },
  sheet: async function (gdiB64, w, h, newB64, oldB64, sx, sy) {
    var a = this.gdi(gdiB64, w, h), b = await this.load(newB64, w, h);
    var o = oldB64 ? await this.load(oldB64, w, h).catch(function () { return a; }) : a;
    var d = new Uint8ClampedArray(w * h * 4);
    for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) {
      var i = (y * w + x) * 4, bx = x + sx, by = y + sy, v = 255, c = [255, 255, 255];
      v = (bx < 0 || by < 0 || bx >= w || by >= h) ? this.white(a, i) : this.diff(a, b, i, (by * w + bx) * 4);
      if (v > this.bad) c = [255, 0, 0]; else if (v > this.inkLevel) c = [255, 192, 192]; else if (this.white(a, i) > this.inkLevel) c = [200, 200, 200];
      d[i] = c[0]; d[i+1] = c[1]; d[i+2] = c[2]; d[i+3] = 255;
    }
    var c = document.createElement('canvas'); c.width = w * 4 + 12; c.height = h;
    var g = c.getContext('2d'); g.fillStyle = '#c0c0c0'; g.fillRect(0, 0, c.width, h);
    [a, b, d, o].forEach(function (px, k) { g.putImageData(new ImageData(px, w, h), k * (w + 4), 0); });
    return c.toDataURL('image/png').split(',')[1];
  }
};
true
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', required=True)
    ap.add_argument('--old', default='')
    ap.add_argument('--worst', type=int, default=20)
    ap.add_argument('--port', type=int, default=9431)
    args = ap.parse_args()
    manifest = json.load(open(os.path.join(args.check, 'manifest.json'), encoding='utf-8-sig'))
    browser = Browser(width=800, height=600, port=args.port)
    results = []
    try:
        browser.eval(JS)

        def b64(path):
            return base64.b64encode(open(path, 'rb').read()).decode('ascii') if path and os.path.exists(path) else ''

        def gdi(name):
            data = open(os.path.join(args.check, name + '.gdi'), 'rb').read()
            w, h = int.from_bytes(data[0:4], 'little'), int.from_bytes(data[4:8], 'little')
            return base64.b64encode(data[8:]).decode('ascii'), w, h

        for n, item in enumerate(manifest, 1):
            name = item['name']
            if item.get('error') or not os.path.exists(os.path.join(args.check, name + '.gdi')):
                results.append({'name': name, 'error': item.get('error', 'нет картинки GDI')})
                continue
            g, w, h = gdi(name)
            r = browser.eval('emf.run(%s, %d, %d, %s, %s)' % (json.dumps(g), w, h,
                                                            json.dumps(b64(os.path.join(args.check, name + '.svg'))),
                                                            json.dumps(b64(os.path.join(args.old, name + '.svg') if args.old else ''))))
            r['name'] = name
            r['bytes'] = item.get('bytes')
            r['ms'] = item.get('ms')
            r['skipped'] = item.get('skipped')
            results.append(r)
            if n % 200 == 0:
                print('  %d' % n, flush=True)
        ok = [r for r in results if 'new' in r]
        worst = sorted(ok, key=lambda r: -r['new']['v'])
        for k, r in enumerate(worst[:args.worst], 1):
            g, w, h = gdi(r['name'])
            png = browser.eval('emf.sheet(%s, %d, %d, %s, %s, %d, %d)' % (
                json.dumps(g), w, h, json.dumps(b64(os.path.join(args.check, r['name'] + '.svg'))),
                json.dumps(b64(os.path.join(args.old, r['name'] + '.svg') if args.old else '')), r['new']['sx'], r['new']['sy']))
            with open(os.path.join(args.check, 'worst_%02d_%s.png' % (k, r['name'])), 'wb') as f:
                f.write(base64.b64decode(png))
    finally:
        browser.close()

    def q(values, p):
        values = sorted(values)
        return round(values[min(len(values) - 1, int(p * len(values)))], 4) if values else None

    new = [r['new']['v'] for r in ok]
    old = [r['old']['v'] for r in ok if 'old' in r]
    pairs = [(r['new']['v'], r['old']['v']) for r in ok if 'old' in r]
    skipped = {}
    for r in results:
        for s in (r.get('skipped') or '').split(','):
            if s:
                k = s.split('×')[0]
                skipped[k] = skipped.get(k, 0) + 1
    shifts = {}
    for r in ok:
        k = '%d,%d' % (r['new']['sx'], r['new']['sy'])
        shifts[k] = shifts.get(k, 0) + 1
    report = {
        'files': len(results), 'errors': [r for r in results if r.get('error') or r.get('newError')][:20],
        'newMedian': q(new, 0.5), 'newP95': q(new, 0.95), 'newP99': q(new, 0.99), 'newMax': q(new, 1),
        'oldMedian': q(old, 0.5), 'oldP95': q(old, 0.95), 'oldMax': q(old, 1),
        'newBetterThanOld': sum(1 for a, b in pairs if a < b - 0.005),
        'newWorseThanOld': sum(1 for a, b in pairs if a > b + 0.005),
        'bestShift': shifts, 'skippedRecordTypes': skipped,
        'msPerFile': round(statistics.mean([r['ms'] for r in ok if r.get('ms') is not None] or [0]), 3),
        'svgBytesAvg': round(statistics.mean([r['bytes'] for r in ok if r.get('bytes')] or [0])),
        'worst': [{'file': r['name'], 'new': round(r['new']['v'], 4), 'old': round(r['old']['v'], 4) if 'old' in r else None,
                   'ink': r['new']['ink']} for r in worst[:40]],
    }
    with open(os.path.join(args.check, 'report.json'), 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in report.items() if k not in ('worst', 'errors')}, ensure_ascii=False))
    print('ошибок: %d' % len(report['errors']))


if __name__ == '__main__':
    main()
