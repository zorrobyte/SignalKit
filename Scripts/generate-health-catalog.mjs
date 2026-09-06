// Emits an apply_patch patch. No private API or runtime reflection.
// Run from the repo root: node Scripts/generate-health-catalog.mjs [Headers dir] [--write]
// Defaults to the selected Xcode's iphoneos SDK HealthKit headers. Without
// --write it prints an apply_patch patch instead of touching the file.
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';
const args=process.argv.slice(2);
const write=args.includes('--write');
const headers=args.find(a=>!a.startsWith('--'))
  ?? `${execFileSync('xcrun',['--sdk','iphoneos','--show-sdk-path'],{encoding:'utf8'}).trim()}/System/Library/Frameworks/HealthKit.framework/Headers`;
if(!fs.existsSync(`${headers}/HKTypeIdentifiers.h`)) throw Error(`No HealthKit headers at ${headers}`);
const source=['HKTypeIdentifiers.h','HKClinicalType.h'].map(f=>fs.readFileSync(`${headers}/${f}`,'utf8')).join('\n');
const families={Quantity:'quantity',Category:'category',Characteristic:'characteristic',Correlation:'correlation',Document:'document',Clinical:'clinical',ScoredAssessment:'assessment'};
let lines=[];
const declarations=[...source.matchAll(/HK_EXTERN HK(Quantity|Category|Characteristic|Correlation|Document|Clinical|ScoredAssessment)TypeIdentifier const (\w+) API_AVAILABLE\(ios\(([\d.]+)\)[^;]+;/g)];
for(const [,kind,symbol,version] of declarations){
 // Swift's SDK overlay initializer validates scored identifiers; standard
 // families retain the nullable factory for availability-safe catalogs.
 // ObjC constant names are unavailable in Swift. Raw values are stable public
 // identifiers; compare against native constants in catalog tests.
 const rawExpression=kind==='ScoredAssessment'?`HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: "${symbol}"))`:`HKObjectType.${kind[0].toLowerCase()+kind.slice(1)}Type(forIdentifier: HK${kind}TypeIdentifier(rawValue: "${symbol}"))`;
 lines.push(`        if #available(iOS ${version}, *) { append(${rawExpression}, family: .${families[kind]}) }`);
}
const result=`// Generated from public HealthKit SDK headers. Regenerate with Scripts/generate-health-catalog.mjs.
// Includes ${declarations.length} identifier-based types; specialized types are added by HealthTypeCatalog.
import HealthKit

extension HealthTypeCatalog {
    static func appendSDKTypes(_ append: (HKObjectType?, Family) -> Void) {
${lines.join('\n').replaceAll(', family: .', ', .')}
    }
}
`;
const path='Sources/HealthSync/HealthTypeCatalog+Generated.swift';
const previous=fs.existsSync(path)?fs.readFileSync(path,'utf8'):null;
if(write){ fs.writeFileSync(path,result); console.log(`Wrote ${path} (${declarations.length} types)`); }
else process.stdout.write('*** Begin Patch\n'+(previous?'*** Update File: '+path+'\n@@\n'+previous.trimEnd().split('\n').map(l=>'-'+l).join('\n')+'\n':'*** Add File: '+path+'\n')+result.trimEnd().split('\n').map(l=>'+'+l).join('\n')+'\n*** End Patch');
