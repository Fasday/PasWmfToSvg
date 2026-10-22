"""Минимальный клиент Chrome DevTools Protocol поверх WebSocket (без сторонних пакетов): Edge или Chrome без окна."""
import base64
import json
import os
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request

BROWSERS = [os.environ.get('MF_BROWSER', ''),
            r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
            r'C:\Program Files\Google\Chrome\Application\chrome.exe',
            '/usr/bin/microsoft-edge', '/usr/bin/google-chrome', '/usr/bin/chromium',
            '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
            '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome']


class WebSocket:
    def __init__(self, url):
        hostport, path = url[5:].split('/', 1)
        host, port = hostport.split(':')
        self.sock = socket.create_connection((host, int(port)), timeout=120)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                           f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        response = b''
        while b'\r\n\r\n' not in response:
            response += self.sock.recv(4096)
        if b' 101 ' not in response.split(b'\r\n')[0]:
            raise RuntimeError(response[:200])
        self.buffer = response.split(b'\r\n\r\n', 1)[1]

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError('closed')
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def send(self, text):
        payload = text.encode('utf-8')
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack('>H', n)
        else:
            header.append(0x80 | 127)
            header += struct.pack('>Q', n)
        mask = os.urandom(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self):
        message = b''
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack('>H', self._read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self._read(8))[0]
            data = self._read(n)
            opcode = b0 & 0x0F
            if opcode == 8:
                raise ConnectionError('close frame')
            if opcode in (0, 1, 2):
                message += data
                if b0 & 0x80:
                    return message.decode('utf-8')


class Browser:
    def __init__(self, width=800, height=600, port=9431, profile=None):
        exe = next((b for b in BROWSERS if b and os.path.exists(b)), None)
        if exe is None:
            raise RuntimeError('нет Edge или Chrome: задайте путь в MF_BROWSER')
        self.profile = profile or os.path.join(tempfile.gettempdir(), 'paswmftosvg_browser')
        self.proc = subprocess.Popen([exe, '--headless=new', '--disable-gpu-sandbox', '--hide-scrollbars',
                                      '--no-first-run', '--no-default-browser-check', f'--remote-debugging-port={port}',
                                      f'--user-data-dir={self.profile}', f'--window-size={width},{height}',
                                      '--force-device-scale-factor=1', 'about:blank'],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        target = None
        for _ in range(100):
            try:
                pages = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/json'))
                target = next(p for p in pages if p.get('type') == 'page')
                break
            except Exception:
                time.sleep(0.2)
        if target is None:
            raise RuntimeError('нет страницы DevTools')
        self.ws = WebSocket(target['webSocketDebuggerUrl'])
        self.next_id = 0
        self.call('Runtime.enable')

    def call(self, method, **params):
        self.next_id += 1
        my_id = self.next_id
        self.ws.send(json.dumps({'id': my_id, 'method': method, 'params': params}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get('id') == my_id:
                if 'error' in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get('result', {})

    def eval(self, expression):
        result = self.call('Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=True)
        if 'exceptionDetails' in result:
            raise RuntimeError(json.dumps(result['exceptionDetails'])[:600])
        return result.get('result', {}).get('value')

    def close(self):
        try:
            self.call('Browser.close')
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
