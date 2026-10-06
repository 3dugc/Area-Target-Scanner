#pragma once
#include <array>
#include <algorithm>
#include <cmath>
namespace atc { namespace math {
using Matrix=std::array<double,16>;
using Quaternion=std::array<double,4>;
inline Matrix identity(){return {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};}
inline Matrix read(const float* values){Matrix m{};for(size_t i=0;i<m.size();++i)m[i]=values[i];return m;}
inline bool rigid(const Matrix& m){
 for(double value:m)if(!std::isfinite(value))return false;
 if(std::fabs(m[12])>=.0001||std::fabs(m[13])>=.0001||std::fabs(m[14])>=.0001||std::fabs(m[15]-1)>=.0001)return false;
 for(int i=0;i<3;++i)for(int j=0;j<3;++j){double dot=0;for(int k=0;k<3;++k)dot+=m[k*4+i]*m[k*4+j];if(std::fabs(dot-(i==j?1:0))>.001)return false;}
 const double determinant=m[0]*(m[5]*m[10]-m[6]*m[9])-m[1]*(m[4]*m[10]-m[6]*m[8])+m[2]*(m[4]*m[9]-m[5]*m[8]);
 return std::fabs(determinant-1)<=.001;
}
inline bool write(const Matrix& m,float* values){
 for(double value:m)if(!std::isfinite(value)||!std::isfinite(static_cast<float>(value)))return false;
 for(size_t i=0;i<m.size();++i)values[i]=static_cast<float>(m[i]);return true;
}
inline Matrix multiply(const Matrix& a,const Matrix& b){Matrix m{};for(int i=0;i<4;++i)for(int j=0;j<4;++j)for(int k=0;k<4;++k)m[i*4+j]+=a[i*4+k]*b[k*4+j];return m;}
inline Matrix inverse(const Matrix& m){auto inv=identity();for(int i=0;i<3;++i){for(int j=0;j<3;++j)inv[i*4+j]=m[j*4+i];for(int j=0;j<3;++j)inv[i*4+3]-=inv[i*4+j]*m[j*4+3];}return inv;}
struct Residual {double translation,rotation;};
inline Residual residual(const Matrix& previous,const Matrix& candidate){
 // T_previous^-1*T_candidate keeps the comparison independent of world origin.
 double squared=0;for(int i=0;i<3;++i){double translation=0;for(int k=0;k<3;++k)translation+=previous[k*4+i]*(candidate[k*4+3]-previous[k*4+3]);squared+=translation*translation;}
 double trace=0;for(int i=0;i<3;++i)for(int k=0;k<3;++k)trace+=previous[k*4+i]*candidate[k*4+i];
 return {std::sqrt(squared),std::acos(std::clamp((trace-1)*.5,-1.0,1.0))};
}
inline Quaternion quaternion(const Matrix& m){
 Quaternion q{};const double trace=m[0]+m[5]+m[10];
 if(trace>0){const double s=2*std::sqrt(trace+1);q={s/4,(m[9]-m[6])/s,(m[2]-m[8])/s,(m[4]-m[1])/s};}
 else if(m[0]>m[5]&&m[0]>m[10]){const double s=2*std::sqrt(1+m[0]-m[5]-m[10]);q={(m[9]-m[6])/s,s/4,(m[1]+m[4])/s,(m[2]+m[8])/s};}
 else if(m[5]>m[10]){const double s=2*std::sqrt(1+m[5]-m[0]-m[10]);q={(m[2]-m[8])/s,(m[1]+m[4])/s,s/4,(m[6]+m[9])/s};}
 else {const double s=2*std::sqrt(1+m[10]-m[0]-m[5]);q={(m[4]-m[1])/s,(m[2]+m[8])/s,(m[6]+m[9])/s,s/4};}
 double norm=0;for(double value:q)norm+=value*value;norm=std::sqrt(norm);for(auto& value:q)value/=norm;return q;
}
inline Matrix interpolate(const Matrix& previous,const Matrix& candidate,double alpha){
 auto a=quaternion(previous),b=quaternion(candidate);double dot=0;for(size_t i=0;i<a.size();++i)dot+=a[i]*b[i];
 if(dot<0){for(auto& value:b)value=-value;dot=-dot;}
 double first=1-alpha,second=alpha;
 if(dot<.9995){const double angle=std::acos(std::clamp(dot,-1.0,1.0)),denominator=std::sin(angle);first=std::sin((1-alpha)*angle)/denominator;second=std::sin(alpha*angle)/denominator;}
 Quaternion q{};double norm=0;for(size_t i=0;i<q.size();++i){q[i]=first*a[i]+second*b[i];norm+=q[i]*q[i];}norm=std::sqrt(norm);for(auto& value:q)value/=norm;
 const auto w=q[0],x=q[1],y=q[2],z=q[3];auto m=identity();
 m[0]=1-2*(y*y+z*z);m[1]=2*(x*y-w*z);m[2]=2*(x*z+w*y);
 m[4]=2*(x*y+w*z);m[5]=1-2*(x*x+z*z);m[6]=2*(y*z-w*x);
 m[8]=2*(x*z-w*y);m[9]=2*(y*z+w*x);m[10]=1-2*(x*x+y*y);
 for(int row=0;row<3;++row)m[row*4+3]=(1-alpha)*previous[row*4+3]+alpha*candidate[row*4+3];
 return m;
}
inline double quaternionAngle(const Matrix& a,const Matrix& b){const auto qa=quaternion(a),qb=quaternion(b);double dot=0;for(size_t i=0;i<4;++i)dot+=qa[i]*qb[i];return 2*std::acos(std::clamp(std::fabs(dot),0.0,1.0));}
}}
