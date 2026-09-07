import * as cheerio from 'cheerio/slim';
import CryptoJS from 'crypto-js';
import JSEncrypt from 'jsencrypt/lib/index.js';
const { load } = cheerio;

// XPTV scripts call these factories directly, independently of $html.
globalThis.createCheerio = () => cheerio;
globalThis.createCryptoJS = () => CryptoJS;
globalThis.loadJSEncrypt = () => JSEncrypt;

// Only the last document is retained, bounded per spider context.
let previousHTML;
let previousDocument;
function document(html) {
    html = String(html || '');
    if (html !== previousHTML) {
        previousDocument = load(html, { xmlMode: false, decodeEntities: true }, false);
        previousHTML = html;
    }
    return previousDocument;
}

function select($, rule) {
    // Drpy chains selectors with &&; XPTV passes ordinary CSS selectors.
    const parts = rule.split('&&').map(part => part.trim()).filter(Boolean);
    let result = $.root();
    for (const part of parts) result = result.find(part);
    return result;
}

globalThis.pdfa = function(html, rule) {
    if (!html || !rule) return [];
    const $ = document(html);
    return select($, String(rule)).toArray().map(node => $.html(node));
};

globalThis.pdfh = function(html, rule) {
    if (!html || !rule) return '';
    const $ = document(html);
    const parts = String(rule).split('&&');
    let attribute = 'Text';
    if (parts.length > 1 || /^(text|html)$/i.test(parts[0].trim())) {
        attribute = parts.pop().trim();
    }
    const selector = parts.join('&&').trim();
    const target = selector ? select($, selector).first() : $.root();
    if (!target.length) return '';
    if (attribute.toLowerCase() === 'text') return target.text().trim();
    if (attribute.toLowerCase() === 'html') return (target.html() || '').trim();
    // With no selector, attributes belong to the fragment's first element.
    return ((selector ? target : target.children().first()).attr(attribute) || '').trim();
};
