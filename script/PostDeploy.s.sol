// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BuildNFT} from "src/BuildNFT.sol";
import {BUIDLRenderer} from "src/BUIDLRenderer.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Step 2: Store renderer HTML + mint genesis brick.
/// Run AFTER RedeployBuildNFT.s.sol succeeds.
///
/// Usage:
///   PRIVATE_KEY=0x... BUILD_NFT=0x... forge script script/PostDeploy.s.sol \
///     --rpc-url https://mainnet.base.org --broadcast -vvv
contract PostDeploy is Script {
    address constant BLOX = 0x6D280a9D90d16F84cea93D541fAAa23aB60b145f;
    address constant RENDERER = 0xbF506c13b57a6CF777C3A2ffe0c58dE898Ff2a40;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address buildNFTAddr = vm.envAddress("BUILD_NFT");
        BuildNFT buildNFT = BuildNFT(buildNFTAddr);

        console.log("--- Step 2: Store Renderer HTML ---");
        vm.startBroadcast(pk);

        _storeRendererHTML(BUIDLRenderer(RENDERER));

        vm.stopBroadcast();

        console.log("--- Step 3: Mint Genesis Brick ---");
        vm.startBroadcast(pk);

        bytes memory genesisGeo = hex"01010101" hex"01";
        bytes32 genesisHash = keccak256(genesisGeo);

        IERC20(BLOX).approve(address(buildNFT), 1e18);
        buildNFT.mint{value: 0.001 ether}(
            genesisHash,
            1,
            genesisGeo,
            new uint256[](0),
            new uint256[](0),
            new BuildNFT.PlacedComponent[](0),
            0,
            1,
            1,
            0
        );
        console.log("Genesis brick minted as token #1");

        vm.stopBroadcast();
    }

    function _storeRendererHTML(BUIDLRenderer renderer) internal {
        bytes memory html = abi.encodePacked(
            "<!DOCTYPE html><html><head><meta charset='utf-8'><style>"
            "*{margin:0;padding:0;overflow:hidden}"
            "body{background:#1a2333;display:flex;align-items:center;justify-content:center;height:100vh}"
            "canvas{max-width:100vw;max-height:100vh;display:block}"
            "</style></head><body><canvas id='c'></canvas><script>"
            "window.addEventListener('DOMContentLoaded',function(){"
            "const P=[[0,0,0],[232,237,245],[224,85,51],[160,114,74],[109,179,79],[79,195,247],[240,200,120],[64,64,80]];"
            "const cv=document.getElementById('c'),gl=cv.getContext('webgl',{antialias:true,alpha:false});"
            "if(!gl){document.body.innerHTML='<div style=\"color:#888;font:16px monospace;text-align:center;margin-top:45vh\">WebGL not supported</div>';return;}"
            "if(typeof BUIDL_GEO==='undefined'){document.body.innerHTML='<div style=\"color:#888;font:16px monospace;text-align:center;margin-top:45vh\">No geometry data</div>';return;}"
            "{"
            "let W=600,H=600;cv.width=W;cv.height=H;"
            "gl.viewport(0,0,W,H);gl.enable(gl.DEPTH_TEST);gl.clearColor(0.102,0.137,0.184,1);"
        );

        bytes memory html2 = abi.encodePacked(
            "const raw=atob(BUIDL_GEO),b=new Uint8Array(raw.length);"
            "for(let i=0;i<raw.length;i++)b[i]=raw.charCodeAt(i);"
            "const bx=b[1],by=b[2],bz=b[3];"
            "const G=new Uint8Array(bx*by*bz);"
            "for(let i=0;i<bx*by*bz;i++){"
            "const bi=(i*3>>3),bo=(i*3)&7;"
            "let ci=(b[4+bi]>>bo)&7;"
            "if(bo>5&&4+bi+1<b.length)ci|=((b[4+bi+1]<<(8-bo))&7);"
            "G[i]=ci;}"
            "function at(x,y,z){if(x<0||x>=bx||y<0||y>=by||z<0||z>=bz)return 0;return G[x+y*bx+z*bx*by];}"
        );

        bytes memory html3 = abi.encodePacked(
            "const verts=[],norms=[],cols=[],edges=[];"
            "const FD=["
            "[0,1,0,[0,1,0],[[0,1,0],[1,1,0],[1,1,1],[0,1,1]]],"
            "[0,-1,0,[0,-1,0],[[0,0,1],[1,0,1],[1,0,0],[0,0,0]]],"
            "[-1,0,0,[-1,0,0],[[0,0,1],[0,1,1],[0,1,0],[0,0,0]]],"
            "[1,0,0,[1,0,0],[[1,0,0],[1,1,0],[1,1,1],[1,0,1]]],"
            "[0,0,-1,[0,0,-1],[[0,0,0],[0,1,0],[1,1,0],[1,0,0]]],"
            "[0,0,1,[0,0,1],[[1,0,1],[1,1,1],[0,1,1],[0,0,1]]]];"
        );

        bytes memory html4 = abi.encodePacked(
            "for(let z=0;z<bz;z++)for(let y=0;y<by;y++)for(let x=0;x<bx;x++){"
            "const ci=at(x,y,z);if(!ci)continue;"
            "const c=P[ci];"
            "for(const[dx,dy,dz,n,corners]of FD){"
            "if(at(x+dx,y+dy,z+dz))continue;"
            "for(const idx of[0,1,2,0,2,3]){"
            "const[cx,cy,cz]=corners[idx];"
            "verts.push(x+cx,y+cy,z+cz);"
            "norms.push(...n);"
            "cols.push(c[0]/255,c[1]/255,c[2]/255);}"
            "for(let i=0;i<4;i++){"
            "const a=corners[i],b2=corners[(i+1)%4];"
            "edges.push(x+a[0],y+a[1],z+a[2],x+b2[0],y+b2[1],z+b2[2]);}}}"
        );

        bytes memory html5 = abi.encodePacked(
            "const gS=Math.max(bx,bz)*3;"
            "const gV=[-gS,0,-gS,gS,0,-gS,gS,0,gS,-gS,0,-gS,gS,0,gS,-gS,0,gS];"
            "const nV=verts.length/3,nE=edges.length/3;"
        );

        bytes memory html6 = abi.encodePacked(
            "const vsrc='"
            "attribute vec3 aP,aN,aC;"
            "uniform mat4 uMVP,uM;"
            "varying vec3 vN,vC,vW;"
            "void main(){"
            "vN=mat3(uM)*aN;vC=aC;"
            "vW=(uM*vec4(aP,1.0)).xyz;"
            "gl_Position=uMVP*vec4(aP,1.0);}';"
        );

        bytes memory html7 = abi.encodePacked(
            "const fsrc='"
            "precision mediump float;"
            "varying vec3 vN,vC,vW;"
            "uniform vec3 uEye;"
            "vec3 aces(vec3 x){"
            "float a=2.51,b=0.03,c=2.43,d=0.59,e=0.14;"
            "return clamp((x*(a*x+b))/(x*(c*x+d)+e),0.0,1.0);}"
            "void main(){"
            "vec3 n=normalize(vN);"
            "vec3 L1=normalize(vec3(0.56,0.75,0.5));"
            "vec3 L2=normalize(vec3(-0.5,0.4,-0.25));"
            "float hemi=n.y*0.5+0.5;"
            "vec3 ambient=mix(vec3(0.16,0.19,0.25),vec3(0.47,0.48,0.5),hemi)*0.45;"
            "float d1=max(dot(n,L1),0.0);"
            "float d2=max(dot(n,L2),0.0);"
            "vec3 diffuse=vC*(d1*0.75+d2*0.25);"
            "vec3 V=normalize(uEye-vW);"
            "vec3 H1=normalize(L1+V);"
            "vec3 H2=normalize(L2+V);"
            "float s1=pow(max(dot(n,H1),0.0),50.0);"
            "float s2=pow(max(dot(n,H2),0.0),25.0);"
            "vec3 spec=mix(vec3(1.0),vC,0.12)*(s1*0.45+s2*0.1);"
            "float rim=pow(1.0-max(dot(n,V),0.0),3.0)*0.15;"
            "vec3 col=ambient*vC+diffuse+spec+vec3(rim);"
            "col=aces(col*1.06);"
            "col=pow(col,vec3(1.0/2.2));"
            "gl_FragColor=vec4(col,1.0);}';"
        );

        bytes memory html8 = abi.encodePacked(
            "const evsrc='attribute vec3 aP;uniform mat4 uMVP;"
            "void main(){gl_Position=uMVP*vec4(aP,1.0);}';"
            "const efsrc='precision mediump float;"
            "void main(){gl_FragColor=vec4(0.06,0.08,0.12,0.3);}';"
            "const gvsrc='attribute vec3 aP;uniform mat4 uMVP,uM;varying vec3 vW;"
            "void main(){vW=(uM*vec4(aP,1.0)).xyz;gl_Position=uMVP*vec4(aP,1.0);}';"
            "const gfsrc='precision mediump float;varying vec3 vW;uniform vec4 uC;"
            "void main(){"
            "float d=length(vW.xz-uC.xy);"
            "float a=smoothstep(uC.z,0.0,d)*0.15;"
            "gl_FragColor=vec4(0.25,0.3,0.42,a);}';"
        );

        bytes memory html9 = abi.encodePacked(
            "function mkS(t,s){const o=gl.createShader(t);gl.shaderSource(o,s);gl.compileShader(o);return o;}"
            "function mkP(v,f){const p=gl.createProgram();gl.attachShader(p,mkS(gl.VERTEX_SHADER,v));gl.attachShader(p,mkS(gl.FRAGMENT_SHADER,f));gl.linkProgram(p);return p;}"
            "const prog=mkP(vsrc,fsrc),eP=mkP(evsrc,efsrc),gP=mkP(gvsrc,gfsrc);"
            "function mkB(d){const o=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,o);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(d),gl.STATIC_DRAW);return o;}"
            "const vB=mkB(verts),nB=mkB(norms),cB=mkB(cols),eB=mkB(edges),gB=mkB(gV);"
        );

        bytes memory html10 = abi.encodePacked(
            "const uMVP=gl.getUniformLocation(prog,'uMVP'),uM=gl.getUniformLocation(prog,'uM'),uEye=gl.getUniformLocation(prog,'uEye');"
            "const euMVP=gl.getUniformLocation(eP,'uMVP');"
            "const guMVP=gl.getUniformLocation(gP,'uMVP'),guM=gl.getUniformLocation(gP,'uM'),guC=gl.getUniformLocation(gP,'uC');"
        );

        bytes memory html11 = abi.encodePacked(
            "function persp(fov,asp,n,f){const t=1/Math.tan(fov/2),d=f-n;return[t/asp,0,0,0,0,t,0,0,0,0,-(f+n)/d,-1,0,0,-2*f*n/d,0];}"
            "function lAt(e,c,u){const z=n3(s3(e,c)),x=n3(c3(u,z)),y=c3(z,x);return[x[0],y[0],z[0],0,x[1],y[1],z[1],0,x[2],y[2],z[2],0,-d3(x,e),-d3(y,e),-d3(z,e),1];}"
            "function m4(a,b){const r=[];for(let i=0;i<4;i++)for(let j=0;j<4;j++){let v=0;for(let k=0;k<4;k++)v+=a[k*4+i]*b[j*4+k];r[j*4+i]=v;}return r;}"
            "function s3(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}"
            "function c3(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}"
            "function d3(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}"
            "function n3(v){const l=Math.sqrt(d3(v,v))||1;return[v[0]/l,v[1]/l,v[2]/l];}"
            "function tr(x,y,z){return[1,0,0,0,0,1,0,0,0,0,1,0,x,y,z,1];}"
        );

        bytes memory html12 = abi.encodePacked(
            "const cx=bx/2,cy=by/2,cz=bz/2;"
            "const maxDim=Math.max(bx,by,bz);"
            "const dist=Math.max(maxDim*2.8,4.5);"
            "let aY=0.78,aX=0.42,drag=false,lx=0,ly=0,auto=true,zm=1.0;"
            "cv.onmousedown=e=>{drag=true;lx=e.clientX;ly=e.clientY;auto=false;};"
            "cv.onmousemove=e=>{if(!drag)return;aY+=(e.clientX-lx)*0.008;aX+=(e.clientY-ly)*0.008;aX=Math.max(-1.2,Math.min(1.2,aX));lx=e.clientX;ly=e.clientY;};"
            "cv.onmouseup=cv.onmouseleave=()=>drag=false;"
            "cv.onwheel=e=>{zm=Math.max(0.4,Math.min(2.5,zm+e.deltaY*0.001));e.preventDefault();};"
            "cv.ontouchstart=e=>{e.preventDefault();drag=true;lx=e.touches[0].clientX;ly=e.touches[0].clientY;auto=false;};"
            "cv.ontouchmove=e=>{if(!drag)return;e.preventDefault();aY+=(e.touches[0].clientX-lx)*0.008;aX+=(e.touches[0].clientY-ly)*0.008;aX=Math.max(-1.2,Math.min(1.2,aX));lx=e.touches[0].clientX;ly=e.touches[0].clientY;};"
            "cv.ontouchend=()=>drag=false;"
        );

        bytes memory html13 = abi.encodePacked(
            "function resize(){const s=Math.min(innerWidth,innerHeight);W=s;H=s;cv.width=s;cv.height=s;gl.viewport(0,0,s,s);}"
            "onresize=resize;resize();"
            "function ba(p,b,n,s){gl.bindBuffer(gl.ARRAY_BUFFER,b);const l=gl.getAttribLocation(p,n);if(l>=0){gl.enableVertexAttribArray(l);gl.vertexAttribPointer(l,s,gl.FLOAT,false,0,0);}}"
            "gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);"
        );

        bytes memory html14 = abi.encodePacked(
            "function draw(){"
            "if(auto)aY+=0.0025;"
            "gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);"
            "const model=tr(-cx,-cy,-cz);"
            "const D=dist*zm;"
            "const eX=D*Math.cos(aX)*Math.sin(aY);"
            "const eY=D*Math.sin(aX);"
            "const eZ=D*Math.cos(aX)*Math.cos(aY);"
            "const eye=[eX,eY,eZ];"
            "const view=lAt(eye,[0,0,0],[0,1,0]);"
            "const proj=persp(0.66,W/H,0.1,maxDim*10);"
            "const mvp=m4(proj,m4(view,model));"
            "const mf=new Float32Array(mvp),modf=new Float32Array(model);"
        );

        bytes memory html15 = abi.encodePacked(
            "gl.useProgram(gP);gl.depthMask(false);"
            "ba(gP,gB,'aP',3);"
            "gl.uniformMatrix4fv(guMVP,false,mf);gl.uniformMatrix4fv(guM,false,modf);"
            "gl.uniform4fv(guC,new Float32Array([0,0,Math.max(bx,bz)*1.5,0]));"
            "gl.drawArrays(gl.TRIANGLES,0,6);"
            "gl.depthMask(true);"
            "gl.useProgram(prog);"
            "ba(prog,vB,'aP',3);ba(prog,nB,'aN',3);ba(prog,cB,'aC',3);"
            "gl.uniformMatrix4fv(uMVP,false,mf);gl.uniformMatrix4fv(uM,false,modf);"
            "gl.uniform3fv(uEye,new Float32Array(eye));"
            "gl.drawArrays(gl.TRIANGLES,0,nV);"
            "gl.useProgram(eP);ba(eP,eB,'aP',3);"
            "gl.uniformMatrix4fv(euMVP,false,mf);"
            "gl.drawArrays(gl.LINES,0,nE);"
            "requestAnimationFrame(draw)}"
            "draw()}"
            "});"
            "</script></body></html>"
        );

        bytes memory fullHtml = abi.encodePacked(html, html2, html3, html4, html5, html6, html7, html8);
        bytes memory fullHtml2 = abi.encodePacked(html9, html10, html11, html12, html13, html14, html15);
        bytes memory combined = abi.encodePacked(fullHtml, fullHtml2);

        renderer.storeRenderer(combined);
        console.log("Renderer HTML stored, size:", combined.length);
    }
}
