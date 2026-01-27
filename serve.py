#!/usr/bin/env python3
"""
Simple HTTP server for testing ZMDB WASM demo
Run: python3 serve.py
Then open: http://localhost:8080/wasm/
"""

import http.server
import socketserver
import os

PORT = 8080

class MyHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Add CORS headers for WASM
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        # Set correct MIME type for WASM
        if self.path.endswith('.wasm'):
            self.send_header('Content-Type', 'application/wasm')
        super().end_headers()

os.chdir(os.path.dirname(os.path.abspath(__file__)))

with socketserver.TCPServer(("", PORT), MyHTTPRequestHandler) as httpd:
    print(f"🚀 Server running at http://localhost:{PORT}/")
    print(f"📱 Open http://localhost:{PORT}/wasm/ to see the demo")
    print("Press Ctrl+C to stop")
    httpd.serve_forever()
