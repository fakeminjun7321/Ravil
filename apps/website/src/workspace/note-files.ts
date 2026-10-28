import type {NoteAttachment} from './note-format';
import {attachmentID} from './note-format';
let pdfRuntime:Promise<typeof import('pdfjs-dist')>|undefined;
export async function pdfJS(){if(!pdfRuntime)pdfRuntime=(async()=>{const pdf=await import('pdfjs-dist');const worker=await import('pdfjs-dist/build/pdf.worker.min.mjs?url');pdf.GlobalWorkerOptions.workerSrc=worker.default;return pdf;})();return pdfRuntime;}
export async function previewPDF(bytes:Uint8Array,pageNumber=1){const pdf=await pdfJS();const loading=pdf.getDocument({data:bytes.slice()});const document=await loading.promise;try{const page=await document.getPage(pageNumber);const view=page.getViewport({scale:1.3});const canvas=window.document.createElement('canvas');canvas.width=Math.ceil(view.width);canvas.height=Math.ceil(view.height);const context=canvas.getContext('2d')!;await page.render({canvas,canvasContext:context,viewport:view}).promise;const blob=await new Promise<Blob>((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new Error('PDF 미리보기를 만들지 못했습니다.')),'image/png'));return {blob,pages:document.numPages};}finally{await loading.destroy();}}
export async function uploadNoteFile(file:File):Promise<{image?:NoteAttachment;original:NoteAttachment}> {
  if(file.size>20*1024*1024)throw new Error('파일당 20MB까지 넣을 수 있어요.');
  const mime=file.type||(/\.pdf$/i.test(file.name)?'application/pdf':'application/octet-stream');
  const upload=async(blob:Blob,name:string,type:string):Promise<NoteAttachment>=>{const id=crypto.randomUUID();const response=await fetch('/api/files/'+id,{method:'PUT',credentials:'include',headers:{'Content-Type':type,'X-File-Name':encodeURIComponent(name)},body:blob});const result=await response.json();if(!response.ok)throw new Error(result.error||'파일을 저장하지 못했습니다.');return {id,name,mime:type,size:blob.size};};
  if(mime==='application/pdf'){const bytes=new Uint8Array(await file.arrayBuffer());const preview=await previewPDF(bytes);const original=await upload(file,file.name,mime);const image=await upload(preview.blob,file.name+' · 미리보기.png','image/png');image.sourceId=original.id;image.pageCount=preview.pages;original.pageCount=preview.pages;return {original,image};}
  if(/^image\/(png|jpeg|webp)$/.test(mime)){const image=await upload(file,file.name,mime);return {original:image,image};}
  const original=await upload(file,file.name,mime);return {original};
}
export async function loadNoteAttachment(id:string):Promise<{bytes:Uint8Array;mime:string}> {if(!attachmentID('/api/files/'+id))throw new Error('파일 주소를 확인해 주세요.');const response=await fetch('/api/files/'+id,{credentials:'include'});if(!response.ok)throw new Error('연결된 파일을 불러오지 못했습니다. 로그인과 원본을 확인해 주세요.');return {bytes:new Uint8Array(await response.arrayBuffer()),mime:response.headers.get('Content-Type')||'application/octet-stream'};}
export async function imageData(bytes:Uint8Array,mime:string):Promise<{dataUrl:string;width:number;height:number;png:Uint8Array}> {
  let source:ImageBitmap|HTMLImageElement;let url:string|undefined;
  if(mime==='image/svg+xml'){
    // ImageBitmap cannot decode SVG in every browser; rasterize the generated equation through an image element.
    const text=new TextDecoder().decode(bytes).replace(/width="([0-9.]+)"/,(_all,n)=>'width="'+(Number(n)*3)+'"').replace(/height="([0-9.]+)"/,(_all,n)=>'height="'+(Number(n)*3)+'"');
    url=URL.createObjectURL(new Blob([text],{type:mime}));const image=new Image();image.src=url;
    try{await image.decode();source=image;}catch{URL.revokeObjectURL(url);throw new Error('수식 이미지를 변환하지 못했습니다.');}
  }else source=await createImageBitmap(new Blob([bytes as BlobPart],{type:mime}));
  try{const width=source instanceof HTMLImageElement?source.naturalWidth:source.width,height=source instanceof HTMLImageElement?source.naturalHeight:source.height;
    const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;canvas.getContext('2d')!.drawImage(source,0,0);
    const png=await new Promise<Blob>((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new Error('이미지를 변환하지 못했습니다.')),'image/png'));
    return {dataUrl:canvas.toDataURL('image/png'),width,height,png:new Uint8Array(await png.arrayBuffer())};
  }finally{if(source instanceof ImageBitmap)source.close();if(url)URL.revokeObjectURL(url);}
}
export async function pdfPageImages(bytes:Uint8Array,onPage:(image:{png:Uint8Array;width:number;height:number;dataUrl:string},index:number,total:number)=>Promise<void>) {const pdf=await pdfJS();const loading=pdf.getDocument({data:bytes.slice()});const doc=await loading.promise;try{for(let i=1;i<=doc.numPages;i++){const page=await doc.getPage(i);const viewport=page.getViewport({scale:1.35});const canvas=document.createElement('canvas');canvas.width=Math.ceil(viewport.width);canvas.height=Math.ceil(viewport.height);await page.render({canvas,canvasContext:canvas.getContext('2d')!,viewport}).promise;const blob=await new Promise<Blob>((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(new Error('PDF 페이지를 변환하지 못했습니다.')),'image/png'));await onPage({png:new Uint8Array(await blob.arrayBuffer()),width:canvas.width,height:canvas.height,dataUrl:canvas.toDataURL('image/png')},i,doc.numPages);canvas.width=0;canvas.height=0;page.cleanup();}}finally{await loading.destroy();}}
