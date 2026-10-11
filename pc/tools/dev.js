'use strict';
// 개발용: 실제 노트(문서\PencilNote)를 건드리지 않도록 시험용 폴더와 다른 포트로 서버를 띄운다.
const path = require('path');

process.env.PENCILNOTE_PORT = process.env.PENCILNOTE_PORT || '8799';
process.env.PENCILNOTE_DATA = process.env.PENCILNOTE_DATA || path.join(__dirname, '..', '..', '.testdata');
require('../server.js');
