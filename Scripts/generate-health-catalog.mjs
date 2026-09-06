// Emits an apply_patch patch. No private API or runtime reflection.
// Run: node Scripts/generate-health-catalog.mjs /path/to/HealthKit.framework/Headers
import fs from 'node:fs';
const headers=process.argv[2];
if(!headers) throw Error('Provide the public HealthKit SDK Headers directory');
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
process.stdout.write('*** Begin Patch\n'+(previous?'*** Update File: '+path+'\n@@\n'+previous.trimEnd().split('\n').map(l=>'-'+l).join('\n')+'\n':'*** Add File: '+path+'\n')+result.trimEnd().split('\n').map(l=>'+'+l).join('\n')+'\n*** End Patch');
