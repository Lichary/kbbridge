#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mock_mac_server.py — 假扮 macOS 侧代理，用来在没有 Mac 的情况下验证 Windows 侧。

它实现 PROTOCOL.md 里服务端的全部行为：握手校验 token、打印收到的按键、
在收到指定数量的 key 事件后主动下发 {"t":"release"}（用来测试「交还键盘」路径），
并且支持客户端断线重连（会重新 accept）。

用法:
    python mock_mac_server.py --port 38471 --token testtoken --release-after 3 --seconds 30
"""

import argparse
import json
import socket
import sys
import time

VK_NAMES = {
    0x41: ('A', 0x00), 0x53: ('S', 0x01), 0x44: ('D', 0x02), 0x46: ('F', 0x03),
    0x48: ('H', 0x04), 0x47: ('G', 0x05), 0x5A: ('Z', 0x06), 0x58: ('X', 0x07),
    0x43: ('C', 0x08), 0x56: ('V', 0x09), 0x42: ('B', 0x0B), 0x51: ('Q', 0x0C),
    0x57: ('W', 0x0D), 0x45: ('E', 0x0E), 0x52: ('R', 0x0F), 0x59: ('Y', 0x10),
    0x54: ('T', 0x11), 0x4D: ('M', 0x2E), 0x4F: ('O', 0x1F), 0x55: ('U', 0x20),
    0x49: ('I', 0x22), 0x50: ('P', 0x23), 0x4C: ('L', 0x25), 0x4A: ('J', 0x26),
    0x4B: ('K', 0x28), 0x4E: ('N', 0x2D),
    0x30: ('0', 0x1D), 0x31: ('1', 0x12), 0x32: ('2', 0x13), 0x33: ('3', 0x14),
    0x34: ('4', 0x15), 0x35: ('5', 0x17), 0x36: ('6', 0x16), 0x37: ('7', 0x1A),
    0x38: ('8', 0x1C), 0x39: ('9', 0x19),
    0xA0: ('LShift', 0x38), 0xA1: ('RShift', 0x3C),
    0xA2: ('LCtrl', 0x3B), 0xA3: ('RCtrl', 0x3E),
    0xA4: ('LOpt/Alt', 0x3A), 0xA5: ('ROpt/Alt', 0x3D),
    0x5B: ('LWin/Cmd', 0x37), 0x5C: ('RWin/Cmd', 0x36),
    0x20: ('Space', 0x31), 0x0D: ('Enter', 0x24), 0x09: ('Tab', 0x30),
    0x1B: ('Esc', 0x35), 0x08: ('Backspace', 0x33), 0x14: ('CapsLock', 0x39),
}


def describe(vk, down):
    name = VK_NAMES.get(vk)
    label = name[0] if name else ('VK_0x%02X' % vk)
    return ('%s %s' % (label, 'down' if down else 'up  '))


def now():
    return time.strftime('%H:%M:%S')


def serve_one(conn, addr, args, state):
    conn.settimeout(1.0)
    f = conn.makefile('rwb', buffering=0)
    print('[%s] 连接来自 %s:%d' % (now(), addr[0], addr[1]))

    hello = f.readline()
    if not hello:
        print('[%s] 空连接，忽略' % now())
        return
    try:
        msg = json.loads(hello.decode('utf-8'))
    except Exception as e:
        print('[%s] 握手报文解析失败: %s' % (now(), e))
        return

    print('[%s] hello: %s' % (now(), json.dumps(msg, ensure_ascii=False)))
    if msg.get('t') != 'hello' or msg.get('token') != args.token:
        f.write((json.dumps({'t': 'hello_err', 'reason': 'bad_token'}) + '\n').encode('utf-8'))
        print('[%s] token 不匹配 -> hello_err' % now())
        conn.close()
        return

    f.write((json.dumps({'t': 'hello_ok', 'proto': 1, 'agent': 'mock-mac', 'version': 'mock'}) + '\n').encode('utf-8'))
    print('[%s] -> hello_ok' % now())

    keys_in = 0
    released = False
    deadline = time.time() + args.seconds

    while time.time() < deadline:
        try:
            raw = f.readline()
        except socket.timeout:
            # 客户端可能还活着但没说话；检查是否需要下发 release
            if args.release_after and not released and keys_in >= args.release_after:
                f.write((json.dumps({'t': 'release', 'reason': 'hotkey'}) + '\n').encode('utf-8'))
                released = True
                print('[%s] -> release（已收到 %d 个按键）' % (now(), keys_in))
            continue
        except OSError:
            break

        if not raw:
            print('[%s] 客户端断开' % now())
            break

        line = raw.decode('utf-8').strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:
            print('[%s] 非法行: %r' % (now(), line))
            continue

        t = m.get('t')
        if t == 'key':
            keys_in += 1
            state['keys'] += 1
            print('[%s] key #%d  %s   (vk=%d)' % (now(), keys_in, describe(m.get('vk', 0), m.get('down', False)), m.get('vk', 0)))
        elif t == 'reset':
            print('[%s] reset（清空修饰键状态）' % now())
        elif t == 'ping':
            f.write((json.dumps({'t': 'pong', 'ts': m.get('ts')}) + '\n').encode('utf-8'))
        elif t == 'bye':
            print('[%s] bye' % now())
            break
        else:
            print('[%s] 未知报文: %s' % (now(), line))

        if args.release_after and not released and keys_in >= args.release_after:
            f.write((json.dumps({'t': 'release', 'reason': 'hotkey'}) + '\n').encode('utf-8'))
            released = True
            print('[%s] -> release（已收到 %d 个按键）' % (now(), keys_in))

    try:
        conn.close()
    except Exception:
        pass
    print('[%s] 本次会话结束，共收到 %d 个按键' % (now(), keys_in))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bind', default='127.0.0.1', help='监听地址，默认 127.0.0.1')
    ap.add_argument('--port', type=int, default=38471)
    ap.add_argument('--token', default='testtoken')
    ap.add_argument('--release-after', type=int, default=3, help='收到 N 个按键后下发 release；0 = 不下发')
    ap.add_argument('--seconds', type=int, default=30, help='总运行秒数')
    args = ap.parse_args()

    state = {'keys': 0}
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(4)
    srv.settimeout(1.0)
    print('mock mac server 监听 %s:%d  (token=%s, release-after=%d, %ds 后退出)'
          % (args.bind, args.port, args.token, args.release_after, args.seconds))

    start = time.time()
    while time.time() - start < args.seconds:
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        try:
            serve_one(conn, addr, args, state)
        except Exception as e:
            print('会话异常: %s' % e)

    srv.close()
    print('退出：累计收到 %d 个按键事件' % state['keys'])


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
