#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EPUB メタデータ・spine順画像リスト抽出ツール

Usage:
    python EpubMetadata.py <epub_extracted_dir>

Output (stdout):
    JSON: { title, creator, vol_num, series_title, images_in_order, opf_path, error }
"""

import sys
import os
import json
import re
import xml.etree.ElementTree as ET


IMG_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp', '.avif', '.gif', '.bmp'}
CONTENT_EXTENSIONS = {'.xhtml', '.html', '.htm', '.xml'}


def strip_ns(tag):
    """名前空間を除去する"""
    return re.sub(r'\{[^}]+\}', '', tag)


def find_opf_path(epub_dir):
    """META-INF/container.xml からOPFファイルのパスを取得する"""
    container_path = os.path.join(epub_dir, 'META-INF', 'container.xml')
    if not os.path.exists(container_path):
        return None
    try:
        tree = ET.parse(container_path)
        root = tree.getroot()
        # 名前空間あり・なし両対応
        for elem in root.iter():
            if strip_ns(elem.tag) == 'rootfile':
                path = elem.get('full-path')
                if path:
                    return path
    except Exception:
        pass
    return None


def parse_opf(epub_dir, opf_rel_path):
    """
    OPFファイルを解析し、メタデータとspine順画像リストを返す

    Returns:
        dict: title, creator, vol_num, series_title, images_in_order, opf_path
    """
    opf_path = os.path.normpath(os.path.join(epub_dir, opf_rel_path.replace('/', os.sep)))
    opf_dir  = os.path.dirname(opf_path)

    if not os.path.exists(opf_path):
        return {'error': f'OPF file not found: {opf_path}'}

    try:
        tree = ET.parse(opf_path)
        root = tree.getroot()
    except Exception as e:
        return {'error': f'OPF parse error: {e}'}

    # ── メタデータ抽出 ──────────────────────────────────────
    title        = None
    creator      = None
    vol_num      = None
    series_title = None
    description  = None

    for elem in root.iter():
        tag = strip_ns(elem.tag)
        text = (elem.text or '').strip()
        if not text:
            continue
        if tag == 'title' and title is None:
            title = text
        elif tag == 'creator' and creator is None:
            creator = text
        elif tag == 'description' and description is None:
            description = text
        elif tag == 'meta':
            prop = elem.get('property', '')
            name = elem.get('name', '')
            content = elem.get('content', text)
            # EPUB3: belongs-to-collection / group-position
            if 'belongs-to-collection' in prop and series_title is None:
                series_title = text
            elif 'group-position' in prop and vol_num is None:
                try:
                    vol_num = int(float(text))
                except ValueError:
                    pass
            # EPUB2 互換 meta
            elif name == 'calibre:series' and series_title is None:
                series_title = content
            elif name == 'calibre:series_index' and vol_num is None:
                try:
                    vol_num = int(float(content))
                except ValueError:
                    pass

    # タイトルから巻番号を補完
    if vol_num is None and title:
        patterns = [
            r'第\s*0*(\d{1,3})\s*巻',
            r'[（(]\s*0*(\d{1,3})\s*[）)]',
            r'\s+0*(\d{1,3})\s*$',
            r'_0*(\d{1,3})(?:_|\s|$)',
            r'(?i)\bvol\.?\s*0*(\d{1,3})\b',
        ]
        for pat in patterns:
            m = re.search(pat, title)
            if m:
                try:
                    vol_num = int(m.group(1))
                    break
                except ValueError:
                    pass

    # ── マニフェスト（id → 絶対パス）────────────────────────
    manifest = {}
    cover_image_path = None  # properties="cover-image" で明示されたカバー
    for elem in root.iter():
        if strip_ns(elem.tag) == 'item':
            item_id    = elem.get('id', '')
            href       = elem.get('href', '')
            media_type = elem.get('media-type') or elem.get('media_type', '')
            properties = elem.get('properties', '')
            if item_id and href:
                abs_path = os.path.normpath(
                    os.path.join(opf_dir, href.replace('/', os.sep))
                )
                manifest[item_id] = {
                    'href': href,
                    'abs_path': abs_path,
                    'media_type': media_type,
                }
                # EPUB3 cover-image プロパティ
                if 'cover-image' in properties:
                    ext = os.path.splitext(abs_path)[1].lower()
                    if ext in IMG_EXTENSIONS and os.path.exists(abs_path):
                        cover_image_path = abs_path

    # ── spine 順で画像リストを構築 ────────────────────────────
    spine_idrefs = []
    for elem in root.iter():
        if strip_ns(elem.tag) == 'spine':
            for child in elem:
                idref = child.get('idref', '')
                if idref:
                    spine_idrefs.append(idref)

    images_in_order = []
    seen_paths = set()

    def add_image(path):
        norm = os.path.normcase(path)
        if norm not in seen_paths and os.path.exists(path):
            ext = os.path.splitext(path)[1].lower()
            if ext in IMG_EXTENSIONS:
                seen_paths.add(norm)
                images_in_order.append(path)

    for idref in spine_idrefs:
        if idref not in manifest:
            continue
        item = manifest[idref]
        abs_path = item['abs_path']
        ext = os.path.splitext(abs_path)[1].lower()

        if ext in IMG_EXTENSIONS:
            add_image(abs_path)
        elif ext in CONTENT_EXTENSIONS and os.path.exists(abs_path):
            # XHTML/HTML から画像参照を抽出（<img src>, SVG <image xlink:href/href> 対応）
            try:
                content = open(abs_path, encoding='utf-8', errors='replace').read()
                xhtml_dir = os.path.dirname(abs_path)
                src_list = []
                # HTML <img src="...">
                src_list += re.findall(r'<img[^>]+src=["\']([^"\']+)["\']', content, re.IGNORECASE)
                # SVG <image xlink:href="..."> or <image href="...">
                src_list += re.findall(r'<image[^>]+xlink:href=["\']([^"\']+)["\']', content, re.IGNORECASE)
                src_list += re.findall(r'<image[^>]+(?<!xlink:)href=["\']([^"\']+)["\']', content, re.IGNORECASE)
                for src in src_list:
                    # クエリ文字列・フラグメントを除去
                    src = src.split('?')[0].split('#')[0]
                    if not src:
                        continue
                    img_abs = os.path.normpath(
                        os.path.join(xhtml_dir, src.replace('/', os.sep))
                    )
                    add_image(img_abs)
            except Exception:
                pass

    # spine から画像が取れなかった場合はマニフェスト内の画像を探す（フォールバック）
    if not images_in_order:
        for item in manifest.values():
            add_image(item['abs_path'])

    return {
        'title':             title,
        'creator':           creator,
        'vol_num':           vol_num,
        'series_title':      series_title,
        'cover_image_path':  cover_image_path,
        'images_in_order':   images_in_order,
        'opf_path':          opf_path,
        'error':             None,
    }


def main():
    if len(sys.argv) < 2:
        print(json.dumps({'error': 'Usage: EpubMetadata.py <epub_extracted_dir>'}, ensure_ascii=False))
        sys.exit(1)

    epub_dir = sys.argv[1]
    if not os.path.isdir(epub_dir):
        print(json.dumps({'error': f'Directory not found: {epub_dir}'}, ensure_ascii=False))
        sys.exit(1)

    opf_rel = find_opf_path(epub_dir)
    if not opf_rel:
        print(json.dumps({'error': 'META-INF/container.xml が見つからないか、OPFパスを取得できません（有効なEPUBではない可能性）'}, ensure_ascii=False))
        sys.exit(1)

    result = parse_opf(epub_dir, opf_rel)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
