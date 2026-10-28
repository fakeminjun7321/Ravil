declare module 'pdfmake/build/pdfmake.js' {
  const pdfMake:{addVirtualFileSystem(files:Record<string,string>):void;addFonts(fonts:Record<string,Record<string,string>>):void;createPdf(definition:any):{getBuffer():Promise<Uint8Array>}};
  export default pdfMake;
}
declare module 'pdfmake' {
  const pdfMake:{setLocalAccessPolicy(policy:(path:string)=>boolean):void;addFonts(fonts:Record<string,Record<string,string>>):void;createPdf(definition:any):{getBuffer():Promise<Uint8Array>}};
  export default pdfMake;
}
