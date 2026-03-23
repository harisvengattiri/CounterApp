# 🕌 Imam - Qibla & Prayer Time App (Offline)

A simple and efficient Flutter application that helps users find the Qibla direction and view the next prayer time based on their current location - even without internet connectivity.

---

## ✨ Features

- 📍 Qibla Direction
  - Accurate direction pointing towards the Kaaba (Mecca)
  - Uses device sensors (compass & magnetometer)

- 🕒 Next Prayer Time
  - Calculates upcoming prayer based on location
  - Works completely offline

- 📿 Tasbeeh Counter
  - Simple digital counter for dhikr

- 📡 Offline Support
  - No internet required after installation
  - Uses local calculations and device sensors

- 🔄 Smart Location Handling
  - Live updates when GPS is ON
  - Fallback to last known location when GPS is OFF

---

## 🛠️ Built With

- Flutter (Dart)
- GPS / Location Services
- Device Sensors (Compass)

---

## 📦 Installation

- Download the APK from the Releases section
- Enable Install from Unknown Sources
- Install and open the app

---

## 🚀 How It Works

- The app fetches your latitude & longitude using GPS
- Prayer times are calculated using offline methods
- Qibla direction is calculated relative to the Kaaba (Mecca)
- If GPS is unavailable, the app uses the last known location

---

## ⚠️ Notes

- Qibla accuracy depends on proper compass calibration
- Sensor quality may vary across devices
- App reconnects automatically when GPS is turned back ON

---

## 🔐 Permissions

- Location (for prayer time & Qibla)
- Sensors (for compass)

---

## 🧪 Version

- v1.2 – Stability Update
  - Improved GPS handling (OFF → ON recovery)
  - Better prayer time reliability
  - Enhanced Qibla accuracy
  - Bug fixes and performance improvements

---

## 💡 Future Plans

- Prayer notifications & reminders
- Hijri calendar
- Multiple calculation methods
- UI/UX improvements

---

## 🤝 Contributing

- Contributions and suggestions are welcome

---

## 📄 License

- This project is licensed under the MIT License

---

## 🙏 Acknowledgement

- Built to provide a simple, reliable, and offline-friendly Islamic utility for daily use
