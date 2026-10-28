import type {ScheduledBlock} from './domain.ts';

const stamp=(value:string)=>new Date(value).toISOString().replace(/[-:]/g,'').replace(/\.\d{3}/,'');
const escapeText=(value:string)=>value.replace(/\\/g,'\\\\').replace(/\r\n|\r|\n/g,'\\n').replace(/,/g,'\\,').replace(/;/g,'\\;');

// RFC 5545 section 3.1: fold by UTF-8 octets without splitting a code point.
function fold(line:string):string[]{
  const result:string[]=[];let current='',length=0;
  for(const character of line){const bytes=new TextEncoder().encode(character).length;if(length+bytes>75){result.push(current);current=' ';length=1;}current+=character;length+=bytes;}
  result.push(current);return result;
}

export function calendarFile(blocks:ScheduledBlock[],now=new Date()):string{
  const lines=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//RAVIL//Study plan//KO',...blocks.flatMap(block=>[
    'BEGIN:VEVENT','UID:'+escapeText(block.id)+'@ravil.app','DTSTAMP:'+stamp(now.toISOString()),
    'DTSTART:'+stamp(block.start),'DTEND:'+stamp(block.end),'SUMMARY:'+escapeText(block.title),'END:VEVENT',
  ]),'END:VCALENDAR'];
  return lines.flatMap(fold).join('\r\n')+'\r\n';
}
