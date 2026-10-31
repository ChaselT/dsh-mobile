// 极简静态服务：把预览页发给手机（仅局域网、只读）
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve } from 'node:path'

const root = resolve(import.meta.dirname)
const port = Number(process.env.PORT ?? 8788)
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon' }

createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://x')
    let p = normalize(join(root, decodeURIComponent(url.pathname)))
    if (!p.startsWith(root)) { res.writeHead(403).end('forbidden'); return }
    const info = await stat(p).catch(() => null)
    if (info?.isDirectory()) p = join(p, 'index.html')
    const body = await readFile(p)
    res.writeHead(200, {
      'content-type': types[extname(p)] ?? 'application/octet-stream',
      'cache-control': 'no-store',
    }).end(body)
  } catch (err) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found')
  }
}).listen(port, '0.0.0.0', () => {
  console.log(`preview on http://0.0.0.0:${port}`)
})
